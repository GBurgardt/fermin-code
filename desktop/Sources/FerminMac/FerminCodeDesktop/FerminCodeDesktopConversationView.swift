import AppKit
import FerminCore
import SwiftUI
import UniformTypeIdentifiers

struct FerminCodeDesktopConversationView: View {
    @EnvironmentObject private var store: FerminCodeDesktopStore
    @State private var transcriptVisibleMessageLimit =
        FerminCodeDesktopTranscriptWindowPolicy.initialLimit

    var body: some View {
        Group {
            if let session = store.selectedSession, let route = store.selectedRoute {
                VStack(spacing: 0) {
                    sessionHeader(session: session, route: route)
                    commandStatus
                    runtimeFailureStatus(session: session)
                    Rectangle().fill(FerminCodeDesktopPalette.separator).frame(height: 0.5)
                    FerminCodeDesktopTranscript(
                        store: store,
                        visibleMessageLimit: $transcriptVisibleMessageLimit
                    )
                    .equatable()
                    Rectangle().fill(FerminCodeDesktopPalette.separator).frame(height: 0.5)
                    if let message = store.composerSendErrorMessage {
                        FerminCodeDesktopComposerSendError(message: message)
                    }
                    FerminCodeDesktopComposer()
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("fermin.desktop.session.selected")
                .accessibilityValue(
                    FerminCodeDesktopActivityPresentation.label(
                        for: store.effectiveActivityStatus(for: session, route: route)
                    )
                )
                .sheet(isPresented: $store.isRenamePresented) {
                    FerminCodeDesktopRenameView(
                        currentName: session.displayName,
                        isPresented: $store.isRenamePresented
                    )
                    .environmentObject(store)
                }
                .alert("Archivar sesión", isPresented: $store.isArchiveConfirmationPresented) {
                    Button("Cancelar", role: .cancel) {}
                    Button("Archivar", role: .destructive) {
                        Task { await store.archiveSelectedSession() }
                    }
                    .disabled(store.isArchivingSelectedSession)
                    .accessibilityIdentifier("fermin.desktop.archive.confirm")
                } message: {
                    Text("La sesión saldrá de la lista activa y seguirá disponible en Historial.")
                }
            } else {
                emptyConversation
            }
        }
        .background(FerminCodeDesktopPalette.canvas)
    }

    private func sessionHeader(
        session: FerminRelaySession,
        route: FerminCodeRelaySessionRoute
    ) -> some View {
        let activityStatus = store.effectiveActivityStatus(for: session, route: route)
        return VStack(spacing: 0) {
            HStack(spacing: 7) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: FerminCodeDesktopActivityPresentation.symbol(
                            for: activityStatus
                        ))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(activityColor(activityStatus))
                            .frame(width: 12, height: 12)
                            .accessibilityHidden(true)
                        Text(session.displayName.isEmpty ? "Sesión sin nombre" : session.displayName)
                            .font(.system(size: 15.5, weight: .semibold))
                            .foregroundColor(FerminCodeDesktopPalette.primary)
                            .lineLimit(1)
                            .help(session.displayName.isEmpty ? "Sesión sin nombre" : session.displayName)
                        Text(route.source.displayName.uppercased())
                            .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                            .tracking(0.65)
                            .foregroundColor(FerminCodeDesktopPalette.accent)
                    }
                    Text(session.projectPath ?? session.projectName ?? "Sin proyecto")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(FerminCodeDesktopPalette.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(session.projectPath ?? session.projectName ?? "Sin proyecto")
                }
                .frame(minWidth: 0, alignment: .leading)
                .layoutPriority(1)

                Spacer()

                FerminCodeDesktopRuntimeControls(session: session)
                    .fixedSize(horizontal: true, vertical: false)

                if store.canInterruptSelectedSession
                    || store.isInterruptingSelectedSession {
                    Button {
                        Task { await store.interruptSelectedSession() }
                    } label: {
                        HStack(spacing: 5) {
                            if store.isInterruptingSelectedSession {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "stop.fill")
                            }
                            Text(
                                store.isInterruptingSelectedSession
                                    ? "Interrumpiendo…"
                                    : "Interrumpir"
                            )
                        }
                    }
                    .buttonStyle(FerminCodeDesktopButtonStyle())
                    .disabled(!store.canInterruptSelectedSession)
                    .help(
                        store.isInterruptingSelectedSession
                            ? "Interrumpiendo la ejecución"
                            : "Interrumpir la ejecución actual"
                    )
                    .accessibilityIdentifier("fermin.desktop.session.interrupt")
                }

                Button {
                    store.isDeleteConfirmationPresented = true
                } label: {
                    if store.isDeletingSelectedSession {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "trash")
                    }
                }
                .buttonStyle(FerminCodeDesktopIconButtonStyle())
                .disabled(sessionActionIsBusy)
                .help("Eliminar esta sesión definitivamente")
                .accessibilityLabel("Eliminar sesión")
                .accessibilityIdentifier("fermin.desktop.session.delete")

                Menu {
                    Button {
                        store.isRenamePresented = true
                    } label: {
                        Label("Renombrar…", systemImage: "pencil")
                    }
                    Button {
                        Task {
                            await store.setSelectedSessionMinimized(session.isMinimized != true)
                        }
                    } label: {
                        Label(
                            session.isMinimized == true ? "Restaurar" : "Minimizar",
                            systemImage: session.isMinimized == true
                                ? "arrow.up.left.and.arrow.down.right"
                                : "arrow.down.right.and.arrow.up.left"
                        )
                    }
                    Divider()
                    Button {
                        store.isSubagentPresented = true
                    } label: {
                        Label("Crear subagente…", systemImage: "person.badge.plus")
                    }
                    Divider()
                    Button(role: .destructive) {
                        store.isArchiveConfirmationPresented = true
                    } label: {
                        Label("Archivar…", systemImage: "archivebox")
                    }
                    .accessibilityIdentifier("fermin.desktop.session.archive")
                    Button(role: .destructive) {
                        store.isDeleteConfirmationPresented = true
                    } label: {
                        Label("Eliminar definitivamente…", systemImage: "trash")
                    }
                    .accessibilityIdentifier("fermin.desktop.session.delete.menu")
                } label: {
                    if store.isUpdatingSelectedSessionVisibility
                        || store.isArchivingSelectedSession
                        || store.isDeletingSelectedSession {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "ellipsis")
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(
                    width: FerminCodeDesktopMetrics.iconControlSize,
                    height: FerminCodeDesktopMetrics.iconControlSize
                )
                .disabled(sessionActionIsBusy)
                .accessibilityLabel("Más acciones de sesión")
                .accessibilityIdentifier("fermin.desktop.session.more")
            }

        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(FerminCodeDesktopPalette.surface.opacity(0.72))
    }

    private var sessionActionIsBusy: Bool {
        store.isRenamingSelectedSession
            || store.isCreatingSubagentForSelectedSession
            || store.isUpdatingSelectedSessionVisibility
            || store.isArchivingSelectedSession
            || store.isDeletingSelectedSession
    }

    @ViewBuilder
    private var commandStatus: some View {
        if let command = selectedPendingCommand {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("\(commandLabel(command.operation)) · \(stateLabel(command.state))")
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundColor(FerminCodeDesktopPalette.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 24)
            .background(FerminCodeDesktopPalette.accentSoft.opacity(0.68))
            .accessibilityIdentifier("fermin.desktop.command.pending")
        }
    }

    private var selectedPendingCommand: FerminCodeDesktopPendingCommand? {
        guard let route = store.selectedRoute else { return nil }
        return store.pendingCommands.values
            .filter { $0.source == route.source && ($0.windowID == route.windowID || $0.windowID == nil) }
            .filter { presentsProgress(for: $0.operation) }
            .sorted { $0.id < $1.id }
            .first
    }

    @ViewBuilder
    private func runtimeFailureStatus(session: FerminRelaySession) -> some View {
        if let message = FerminCodeDesktopRuntimeFailurePresentation.message(
            activityStatus: session.activityStatus,
            detail: session.runtimeStatusDetail
        ) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(FerminCodeDesktopPalette.danger)
                    .padding(.top, 1)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("No se pudo completar el turno")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(FerminCodeDesktopPalette.primary)
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundColor(FerminCodeDesktopPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(FerminCodeDesktopPalette.danger.opacity(0.08))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("fermin.desktop.runtime.error")
        }
    }

    private var emptyConversation: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)
            Text("Elegí una sesión")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(FerminCodeDesktopPalette.primary)
            Text("Acá aparecen únicamente las sesiones creadas o reanudadas en Fermín Code.")
                .font(.system(size: 12))
                .foregroundColor(FerminCodeDesktopPalette.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("fermin.desktop.conversation.empty")
    }

    private func activityColor(_ activity: String) -> Color {
        switch FerminCodeDesktopActivityPresentation.state(for: activity) {
        case .ready: return FerminCodeDesktopPalette.positive
        case .busy: return FerminCodeDesktopPalette.warning
        case .failed: return FerminCodeDesktopPalette.danger
        case .inactive, .unknown: return FerminCodeDesktopPalette.muted
        }
    }

    private func commandLabel(_ operation: FerminRelayTrackedCommandOperation) -> String {
        switch operation {
        case .createSession: return "CREANDO"
        case .sendMessage: return "ENVIANDO"
        case .interrupt: return "INTERRUMPIENDO"
        case .retryPromptTransform: return "REINTENTANDO"
        case .minimize: return "ACTUALIZANDO"
        case .setPinned: return "FIJANDO"
        case .rename: return "RENOMBRANDO"
        case .archive: return "ARCHIVANDO"
        case .delete: return "ELIMINANDO"
        case .setFeatures: return "FUNCIONES"
        case .setRunMode: return "GOAL"
        case .setModel: return "MODELO"
        case .createSubagent: return "SUBAGENTE"
        case .resumeHistory: return "REANUDANDO"
        case .recoverSession: return "RECUPERANDO"
        }
    }

    private func presentsProgress(for operation: FerminRelayTrackedCommandOperation) -> Bool {
        switch operation {
        case .setFeatures, .setRunMode, .setModel, .minimize, .setPinned, .rename:
            return false
        case .createSession, .sendMessage, .interrupt, .retryPromptTransform,
             .archive, .delete, .createSubagent, .resumeHistory, .recoverSession:
            return true
        }
    }

    private func stateLabel(_ state: FerminRelayDurableCommandState) -> String {
        switch state {
        case .accepted: return "aceptado"
        case .leased: return "tomado"
        case .engineDurable: return "persistido"
        case .sentToChild: return "enviado al subagente"
        case .completed: return "completado"
        case .failed: return "falló"
        case .cancelled: return "cancelado"
        case .unknown: return "estado desconocido"
        }
    }
}

struct FerminCodeDesktopRuntimeControls: View {
    @EnvironmentObject private var store: FerminCodeDesktopStore
    let session: FerminRelaySession
    @State private var selectedModel = ""
    @State private var selectedEffort = ""
    @State private var isRuntimeSettingsPresented = false
    @State private var runtimeDraftsByInstance: [String: FerminCodeDesktopRuntimeDraft] = [:]
    @State private var editingSessionInstanceID = ""
    @State private var baselineModel = ""
    @State private var baselineEffort = ""
    @FocusState private var focusedRuntimeField: RuntimeField?

    private enum RuntimeField {
        case model
    }

    var body: some View {
        HStack(spacing: 4) {
            Button {
                if store.models.isEmpty {
                    Task {
                        guard await store.reloadModelCatalog() else { return }
                        prepareSelection()
                        isRuntimeSettingsPresented = true
                    }
                } else {
                    prepareSelection()
                    isRuntimeSettingsPresented = true
                }
            } label: {
                HStack(spacing: 3) {
                    Text(
                        FerminCodeDesktopRuntimeModelPresentation.compactModelLabel(
                            store.selectedRuntimeModel
                        )
                    )
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundColor(FerminCodeDesktopPalette.secondary)
                    if isModelControlBusy {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.72)
                            .frame(width: 8, height: 12)
                    } else {
                        Text("·")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(FerminCodeDesktopPalette.muted)
                    }
                    Text(
                        FerminCodeDesktopRuntimeModelPresentation.compactEffortLabel(
                            store.selectedReasoningEffort
                        )
                    )
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(FerminCodeDesktopPalette.muted)
                }
                .lineLimit(1)
                .padding(.horizontal, 6)
                .frame(
                    minWidth: 54,
                    maxWidth: 68,
                    minHeight: FerminCodeDesktopMetrics.compactControlHeight
                )
                .ferminCodeRaisedSurface(fill: FerminCodeDesktopPalette.raised)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isModelControlBusy)
            .opacity(
                isModelControlBusy ? 0.72 : 1
            )
            .help(
                modelControlHelp
            )
            .accessibilityLabel("Modelo y razonamiento")
            .accessibilityValue(modelControlAccessibilityValue)
            .accessibilityHint(modelControlAccessibilityHint)
            .accessibilityIdentifier("fermin.desktop.runtime.reveal")
            .popover(isPresented: $isRuntimeSettingsPresented, arrowEdge: .bottom) {
                runtimeSettingsPopover
            }

            Toggle(isOn: goalBinding) {
                HStack(spacing: 3) {
                    Text("GOAL")
                        .font(.system(size: 9.5, weight: .black, design: .monospaced))
                        .tracking(0.4)
                    if store.isUpdatingSelectedGoalMode {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.62)
                            .frame(width: 7, height: 10)
                    }
                }
                .foregroundColor(store.selectedGoalModeEnabled ? .white : FerminCodeDesktopPalette.secondary)
                .frame(width: 38, height: FerminCodeDesktopMetrics.compactControlHeight)
                .ferminCodeRaisedSurface(
                    fill: store.selectedGoalModeEnabled
                        ? FerminCodeDesktopPalette.accent
                        : FerminCodeDesktopPalette.raised,
                    topLight: store.selectedGoalModeEnabled
                        ? FerminCodeDesktopPalette.topLightStrong
                        : FerminCodeDesktopPalette.topLight
                )
                .contentShape(Rectangle())
            }
                .toggleStyle(.button)
                .buttonStyle(.plain)
                .help(
                    store.isUpdatingSelectedGoalMode
                        ? "Guardando Goal Mode…"
                        : (store.hasPendingSelectedGoalModeDraft
                            ? "GOAL se aplicará cuando envíes el mensaje"
                            : "Seleccionar GOAL para el próximo mensaje")
                )
                .accessibilityLabel("Goal Mode")
                .accessibilityValue(goalAccessibilityValue)
                .accessibilityHint("Se aplica al próximo mensaje cuando lo envíes")
                .accessibilityIdentifier("fermin.desktop.runtime.goal")
        }
        .onAppear { prepareSelection() }
        .onChange(of: store.selectedSessionInstanceID) { _ in
            stashRuntimeDraft()
            isRuntimeSettingsPresented = false
            prepareSelection()
        }
        .onChange(of: isRuntimeSettingsPresented) { isPresented in
            if !isPresented { stashRuntimeDraft() }
        }
        .onChange(of: store.selectedRuntimeModel) { _ in
            syncSelectionFromStoreIfAppropriate()
        }
        .onChange(of: store.selectedReasoningEffort) { _ in
            syncSelectionFromStoreIfAppropriate()
        }
        .onChange(of: store.models) { _ in
            reconcileSelectionWithCatalog()
        }
        .onChange(of: selectedModel) { _ in selectDefaultEffortIfNeeded() }
    }

    private var runtimeSettingsPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Modelo y razonamiento")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(FerminCodeDesktopPalette.primary)
                    Text("Se aplica sólo a esta sesión.")
                        .font(.system(size: 10))
                        .foregroundColor(FerminCodeDesktopPalette.muted)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                FerminCodeDesktopSectionLabel(text: "Modelo")
                Picker("Modelo", selection: modelSelectionBinding) {
                    ForEach(store.models) { model in
                        Text(model.displayName).tag(model.model)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .disabled(isApplyingModel)
                .focused($focusedRuntimeField, equals: .model)
                .accessibilityIdentifier("fermin.desktop.runtime.model")
            }

            VStack(alignment: .leading, spacing: 6) {
                FerminCodeDesktopSectionLabel(text: "Razonamiento")
                Picker("Razonamiento", selection: effortSelectionBinding) {
                    ForEach(efforts, id: \.self) { effort in
                        Text(effort.uppercased()).tag(effort)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .disabled(isApplyingModel)
                .accessibilityIdentifier("fermin.desktop.runtime.effort")

                if let effortDescription {
                    Text(effortDescription)
                        .font(.system(size: 11))
                        .foregroundColor(FerminCodeDesktopPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                Spacer()
                Button(hasRuntimeChange ? "Descartar" : "Cerrar") {
                    runtimeDraftsByInstance.removeValue(forKey: editingSessionInstanceID)
                    syncSelection()
                    isRuntimeSettingsPresented = false
                }
                .buttonStyle(FerminCodeDesktopButtonStyle())
                .disabled(isApplyingModel)
                .keyboardShortcut(.cancelAction)
                .help(runtimeDismissHelp)
                .accessibilityHint(runtimeDismissHelp)

                Button {
                    let targetSessionInstanceID = editingSessionInstanceID
                    let model = selectedModel
                    let effort = selectedEffort
                    Task {
                        guard store.selectedSessionInstanceID == targetSessionInstanceID else { return }
                        let applied = await store.setRuntimeModel(
                            model: model,
                            effort: effort
                        )
                        if applied {
                            runtimeDraftsByInstance.removeValue(forKey: targetSessionInstanceID)
                            if editingSessionInstanceID == targetSessionInstanceID {
                                isRuntimeSettingsPresented = false
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if isApplyingModel {
                            ProgressView().controlSize(.small)
                        }
                        Text(isApplyingModel ? "Aplicando…" : "Aplicar")
                    }
                }
                .buttonStyle(FerminCodeDesktopButtonStyle(prominent: true))
                .disabled(!canApplyRuntimeChange)
                .keyboardShortcut(.defaultAction)
                .help(runtimeApplyHelp)
                .accessibilityHint(runtimeApplyHelp)
                .accessibilityIdentifier("fermin.desktop.runtime.apply")
            }
        }
        .padding(10)
        .frame(width: 250)
        .background(FerminCodeDesktopPalette.canvasTop)
        .interactiveDismissDisabled(
            FerminCodeDesktopRuntimePopoverPolicy.blocksInteractiveDismiss(
                isApplying: isApplyingModel
            )
        )
        .onAppear {
            DispatchQueue.main.async { focusedRuntimeField = .model }
        }
        .onDisappear {
            focusedRuntimeField = nil
        }
    }

    private var efforts: [String] {
        guard let model = store.models.first(where: { $0.model == selectedModel }) else {
            return selectedEffort.isEmpty ? [] : [selectedEffort]
        }
        let supported = model.supportedReasoningEfforts.map(\.reasoningEffort)
        return supported.isEmpty ? [model.defaultReasoningEffort].filter { !$0.isEmpty } : supported
    }

    private var effortDescription: String? {
        let fallback = store.models
            .first(where: { $0.model == selectedModel })?
            .supportedReasoningEfforts
            .first(where: {
                $0.reasoningEffort.caseInsensitiveCompare(selectedEffort) == .orderedSame
            })?
            .description
        return FerminCodeDesktopRuntimeModelPresentation.effortDescription(
            selectedEffort,
            fallback: fallback
        )
    }

    private var hasRuntimeChange: Bool {
        selectedModel != (store.selectedRuntimeModel ?? "")
            || selectedEffort.caseInsensitiveCompare(
                store.selectedReasoningEffort ?? ""
            ) != .orderedSame
    }

    private var isApplyingModel: Bool {
        store.isApplyingSelectedRuntimeModel
    }

    private var canApplyRuntimeChange: Bool {
        FerminCodeDesktopRuntimeApplyPolicy.canApply(
            model: selectedModel,
            effort: selectedEffort,
            hasChange: hasRuntimeChange,
            isApplying: isApplyingModel
        )
    }

    private var runtimeApplyHelp: String {
        FerminCodeDesktopRuntimeApplyPolicy.help(
            model: selectedModel,
            effort: selectedEffort,
            hasChange: hasRuntimeChange,
            isApplying: isApplyingModel
        )
    }

    private var runtimeDismissHelp: String {
        if isApplyingModel { return "Esperá a que termine la aplicación." }
        return hasRuntimeChange
            ? "Descartar los cambios y cerrar"
            : "Cerrar el selector"
    }

    private var isModelControlBusy: Bool {
        store.isLoadingModels || isApplyingModel
    }

    private var modelControlHelp: String {
        if isApplyingModel { return "Aplicando modelo y razonamiento…" }
        if store.isLoadingModels { return "Cargando modelos para esta sesión…" }
        if store.models.isEmpty { return "Volver a cargar los modelos" }
        return "Cambiar modelo y razonamiento"
    }

    private var modelControlAccessibilityHint: String {
        store.models.isEmpty
            ? "Vuelve a cargar las opciones de modelo y razonamiento"
            : "Abre el selector de modelo y nivel de razonamiento"
    }

    private var modelControlAccessibilityValue: String {
        let value = FerminCodeDesktopRuntimeModelPresentation.accessibilityValue(
            model: store.selectedRuntimeModel,
            effort: store.selectedReasoningEffort
        )
        if isApplyingModel { return "\(value), aplicando" }
        if store.isLoadingModels { return "\(value), cargando opciones" }
        return value
    }

    private var goalAccessibilityValue: String {
        let value = store.selectedGoalModeEnabled ? "Activado" : "Desactivado"
        if store.hasPendingSelectedGoalModeDraft {
            return "\(value), se aplicará al enviar"
        }
        return store.isUpdatingSelectedGoalMode ? "\(value), actualizando" : value
    }

    private var goalBinding: Binding<Bool> {
        Binding(
            get: { store.selectedGoalModeEnabled },
            set: { enabled in store.stageGoalMode(enabled) }
        )
    }

    private var modelSelectionBinding: Binding<String> {
        Binding(
            get: { selectedModel },
            set: {
                selectedModel = $0
            }
        )
    }

    private var effortSelectionBinding: Binding<String> {
        Binding(
            get: { selectedEffort },
            set: {
                selectedEffort = $0
            }
        )
    }

    private func syncSelection() {
        let authoritativeModel = store.selectedRuntimeModel
        editingSessionInstanceID = store.selectedSessionInstanceID ?? ""
        baselineModel = authoritativeModel ?? ""
        baselineEffort = store.selectedReasoningEffort ?? ""
        selectedModel = FerminCodeDesktopRuntimeCatalogSelectionPolicy.resolvedModel(
            requested: authoritativeModel,
            models: store.models
        ) ?? ""
        selectedEffort = selectedModel == authoritativeModel
            ? store.selectedReasoningEffort ?? ""
            : ""
        selectDefaultEffortIfNeeded()
    }

    private func prepareSelection() {
        let sessionInstanceID = store.selectedSessionInstanceID ?? ""
        editingSessionInstanceID = sessionInstanceID
        baselineModel = store.selectedRuntimeModel ?? ""
        baselineEffort = store.selectedReasoningEffort ?? ""
        guard let draft = runtimeDraftsByInstance[sessionInstanceID],
              store.models.contains(where: { $0.model == draft.model }) else {
            runtimeDraftsByInstance.removeValue(forKey: sessionInstanceID)
            syncSelection()
            return
        }
        selectedModel = draft.model
        selectedEffort = draft.effort
        selectDefaultEffortIfNeeded()
    }

    private func stashRuntimeDraft() {
        guard !editingSessionInstanceID.isEmpty else { return }
        if let draft = FerminCodeDesktopRuntimeDraftPolicy.draft(
            model: selectedModel,
            effort: selectedEffort,
            baselineModel: baselineModel,
            baselineEffort: baselineEffort
        ) {
            runtimeDraftsByInstance[editingSessionInstanceID] = draft
        } else {
            runtimeDraftsByInstance.removeValue(forKey: editingSessionInstanceID)
        }
    }

    private func reconcileSelectionWithCatalog() {
        guard !store.models.isEmpty,
              !store.models.contains(where: { $0.model == selectedModel }) else { return }
        runtimeDraftsByInstance.removeValue(forKey: editingSessionInstanceID)
        syncSelection()
    }

    private func syncSelectionFromStoreIfAppropriate() {
        guard FerminCodeDesktopRuntimeSelectionSyncPolicy.shouldAdoptStoreSelection(
            isPresented: isRuntimeSettingsPresented,
            isApplying: isApplyingModel,
            hasPendingSelection: hasRuntimeChange
        ) else { return }
        runtimeDraftsByInstance.removeValue(forKey: editingSessionInstanceID)
        syncSelection()
    }

    private func selectDefaultEffortIfNeeded() {
        guard !efforts.contains(selectedEffort) else { return }
        selectedEffort = store.models.first(where: { $0.model == selectedModel })?
            .defaultReasoningEffort ?? efforts.first ?? ""
    }
}

private struct FerminCodeDesktopTranscriptRenderSnapshot: Equatable {
    let presentedMessages: [FerminCodeDesktopPresentedMessage]
    let loadedMessageCount: Int
    let reportedMessageCount: Int
    let detailLoadState: FerminCodeDesktopDetailLoadState
    let pendingSubagentDisplayMessage: String?
    let selectedSessionInstanceID: String?
    let selectedRoute: FerminCodeRelaySessionRoute?
    let isProcessing: Bool
    let retryingPromptMessageIDs: Set<String>

    @MainActor
    init(store: FerminCodeDesktopStore, visibleMessageLimit: Int) {
        presentedMessages = store.displayedMessages(limit: visibleMessageLimit)
        loadedMessageCount = store.loadedMessageCount
        reportedMessageCount = store.displayedMessageCount
        detailLoadState = store.detailLoadState
        pendingSubagentDisplayMessage = store.selectedSession?.pendingSubagent?.displayMessage
        selectedSessionInstanceID = store.selectedSessionInstanceID
        selectedRoute = store.selectedRoute
        let status = [
            store.selectedSession?.activityStatus,
            store.selectedSession?.runtimeStatus,
        ]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        isProcessing = store.isSending
            || status.contains("working")
            || status.contains("processing")
        retryingPromptMessageIDs = Set(
            presentedMessages.lazy
                .filter { store.isRetryingPromptTransform(messageID: $0.message.id) }
                .map(\.message.id)
        )
    }
}

private struct FerminCodeDesktopTranscript: View, Equatable {
    let store: FerminCodeDesktopStore
    @Binding private var visibleMessageLimit: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var followsLatest = true
    private let snapshot: FerminCodeDesktopTranscriptRenderSnapshot

    private let bottomAnchorID = "transcript-bottom"

    @MainActor
    init(store: FerminCodeDesktopStore, visibleMessageLimit: Binding<Int>) {
        self.store = store
        _visibleMessageLimit = visibleMessageLimit
        snapshot = FerminCodeDesktopTranscriptRenderSnapshot(
            store: store,
            visibleMessageLimit: visibleMessageLimit.wrappedValue
        )
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.snapshot == rhs.snapshot
    }

    var body: some View {
        let presentedMessages = snapshot.presentedMessages
        let loadedMessageCount = snapshot.loadedMessageCount
        let hiddenMessageCount = FerminCodeDesktopTranscriptWindowPolicy.hiddenCount(
            total: loadedMessageCount,
            visible: presentedMessages.count
        )
        let incompleteSummary = FerminCodeDesktopTranscriptAvailabilityPresentation
            .incompleteSummary(
                loadedCount: loadedMessageCount,
                reportedCount: snapshot.reportedMessageCount
            )
        let messageTailSignature = messageTailSignature(for: presentedMessages)

        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                VStack(spacing: 0) {
                    if let detailError = snapshot.detailLoadState.errorMessage,
                       !presentedMessages.isEmpty {
                        detailFailureBanner(detailError)
                            .frame(maxWidth: FerminCodeDesktopMetrics.transcriptMaxWidth)
                            .padding(.horizontal, FerminCodeDesktopMetrics.contentGutter)
                            .padding(.top, 10)
                    } else if snapshot.detailLoadState.isLoading, !presentedMessages.isEmpty {
                        detailRefreshBanner
                            .frame(maxWidth: FerminCodeDesktopMetrics.transcriptMaxWidth)
                            .padding(.horizontal, FerminCodeDesktopMetrics.contentGutter)
                            .padding(.top, 10)
                    } else if let incompleteSummary, !presentedMessages.isEmpty {
                        incompleteTranscriptBanner(incompleteSummary)
                            .frame(maxWidth: FerminCodeDesktopMetrics.transcriptMaxWidth)
                            .padding(.horizontal, FerminCodeDesktopMetrics.contentGutter)
                            .padding(.top, 10)
                    }

                    List {
                        if hiddenMessageCount > 0 {
                            transcriptListRow(top: 24, bottom: 10) {
                                Button {
                                    loadEarlierMessages(
                                        proxy,
                                        firstVisibleMessageID: presentedMessages.first?.id,
                                        loadedMessageCount: loadedMessageCount
                                    )
                                } label: {
                                    Label(
                                        "Mostrar \(min(hiddenMessageCount, FerminCodeDesktopTranscriptWindowPolicy.pageSize)) anteriores",
                                        systemImage: "arrow.up"
                                    )
                                }
                                .buttonStyle(FerminCodeDesktopButtonStyle())
                                .frame(maxWidth: .infinity)
                                .accessibilityIdentifier("fermin.desktop.transcript.loadEarlier")
                            }
                        }

                        if let pendingSubagentDisplayMessage =
                            snapshot.pendingSubagentDisplayMessage {
                            transcriptListRow(
                                top: FerminCodeDesktopMetrics.messageRowInset,
                                bottom: FerminCodeDesktopMetrics.messageRowInset
                            ) {
                                HStack(alignment: .top, spacing: 9) {
                                    Image(systemName: "person.2.fill")
                                        .foregroundColor(FerminCodeDesktopPalette.accent)
                                    Text(pendingSubagentDisplayMessage)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(FerminCodeDesktopPalette.secondary)
                                    Spacer()
                                }
                                .padding(12)
                                .ferminCodeRaisedSurface(fill: FerminCodeDesktopPalette.accentSoft)
                            }
                        }

                        if presentedMessages.isEmpty {
                            transcriptListRow(top: 24, bottom: 24) {
                                transcriptPlaceholder
                            }
                        } else {
                            ForEach(presentedMessages) { item in
                                transcriptListRow(
                                    top: FerminCodeDesktopMetrics.messageRowInset,
                                    bottom: FerminCodeDesktopMetrics.messageRowInset
                                ) {
                                    FerminCodeDesktopMessageRow(
                                        store: store,
                                        item: item,
                                        isRetryingPromptTransform:
                                        snapshot.retryingPromptMessageIDs.contains(item.message.id)
                                    )
                                    .equatable()
                                        .id(
                                            FerminCodeDesktopTranscriptIdentityPolicy.messageRowID(
                                                route: snapshot.selectedRoute,
                                                messageID: item.id
                                            )
                                        )
                                }
                            }
                        }
                        transcriptListRow(top: 0, bottom: 0) {
                            Color.clear
                                .frame(height: 1)
                                .id(bottomAnchorID)
                                .onAppear { followsLatest = true }
                                .onDisappear { followsLatest = false }
                        }
                    }
                    .listStyle(.plain)
                    .background(FerminCodeDesktopPalette.canvas)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("fermin.desktop.transcript")
                }

                if !followsLatest, !presentedMessages.isEmpty {
                    Button {
                        followsLatest = true
                        scrollToBottom(proxy, animated: true, assertLayout: true)
                    } label: {
                        Label("Ir al final", systemImage: "arrow.down")
                    }
                    .buttonStyle(FerminCodeDesktopButtonStyle(prominent: true))
                    .padding(12)
                    .accessibilityIdentifier("fermin.desktop.transcript.goToBottom")
                }
            }
            .onAppear {
                followsLatest = true
                scrollToBottom(proxy, animated: false, assertLayout: true)
            }
            .onChange(of: snapshot.selectedSessionInstanceID) { _ in
                visibleMessageLimit = FerminCodeDesktopTranscriptWindowPolicy.initialLimit
                followsLatest = true
                scrollToBottom(proxy, animated: false, assertLayout: true)
            }
            .onChange(of: messageTailSignature) { _ in
                guard followsLatest else { return }
                scrollToBottom(proxy, animated: !isProcessing, assertLayout: false)
            }
        }
    }

    @ViewBuilder
    private func transcriptListRow<Content: View>(
        top: CGFloat,
        bottom: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let row = content()
            .frame(maxWidth: FerminCodeDesktopMetrics.transcriptMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .listRowInsets(
                EdgeInsets(
                    top: top,
                    leading: FerminCodeDesktopMetrics.contentGutter,
                    bottom: bottom,
                    trailing: FerminCodeDesktopMetrics.contentGutter
                )
            )
            .listRowBackground(FerminCodeDesktopPalette.canvas)
        if #available(macOS 13.0, *) {
            row.listRowSeparator(.hidden)
        } else {
            row
        }
    }

    private var detailRefreshBanner: some View {
        HStack(spacing: 9) {
            ProgressView()
                .controlSize(.small)
            Text(detailRefreshLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(FerminCodeDesktopPalette.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .ferminCodeRaisedSurface(fill: FerminCodeDesktopPalette.raised)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(detailRefreshLabel)
        .accessibilityIdentifier("fermin.desktop.transcript.refreshing")
    }

    private var detailRefreshLabel: String {
        snapshot.detailLoadState == .revalidating
            ? "Mostrando el final reciente · Actualizando…"
            : "Actualizando conversación…"
    }

    @ViewBuilder
    private var transcriptPlaceholder: some View {
        VStack(spacing: 8) {
            if snapshot.detailLoadState.isLoading {
                ProgressView()
                    .controlSize(.small)
                Text("Cargando conversación…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(FerminCodeDesktopPalette.secondary)
            } else if let detailError = snapshot.detailLoadState.errorMessage {
                Image(systemName: "arrow.clockwise.circle")
                    .font(.system(size: 20, weight: .light))
                    .foregroundColor(FerminCodeDesktopPalette.danger)
                    .accessibilityHidden(true)
                Text("No se pudo cargar la conversación")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(FerminCodeDesktopPalette.primary)
                Text(detailError)
                    .font(.system(size: 12))
                    .foregroundColor(FerminCodeDesktopPalette.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                detailRetryButton
            } else if snapshot.reportedMessageCount > snapshot.loadedMessageCount {
                Image(systemName: "bubble.left.and.exclamationmark.bubble.right")
                    .font(.system(size: 20, weight: .light))
                    .foregroundColor(FerminCodeDesktopPalette.warning)
                    .accessibilityHidden(true)
                Text("Los mensajes todavía no llegaron")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(FerminCodeDesktopPalette.primary)
                Text("La sesión informa actividad, pero el detalle llegó incompleto.")
                    .font(.system(size: 12))
                    .foregroundColor(FerminCodeDesktopPalette.secondary)
                    .multilineTextAlignment(.center)
                detailRetryButton
            } else {
                Image(systemName: "text.bubble")
                    .font(.system(size: 20, weight: .light))
                    .foregroundColor(FerminCodeDesktopPalette.muted)
                    .accessibilityHidden(true)
                Text("Todavía no hay mensajes")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(FerminCodeDesktopPalette.secondary)
                Text("Escribí abajo para empezar esta conversación.")
                    .font(.system(size: 12))
                    .foregroundColor(FerminCodeDesktopPalette.muted)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            transcriptPlaceholderAccessibilityIdentifier
        )
    }

    private func detailFailureBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(FerminCodeDesktopPalette.danger)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("No se pudo actualizar la conversación")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(FerminCodeDesktopPalette.primary)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(FerminCodeDesktopPalette.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            detailRetryButton
        }
        .padding(12)
        .background(FerminCodeDesktopPalette.danger.opacity(0.10))
        .overlay(Rectangle().stroke(FerminCodeDesktopPalette.danger.opacity(0.28)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fermin.desktop.transcript.detailError")
    }

    private func incompleteTranscriptBanner(_ summary: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundColor(FerminCodeDesktopPalette.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Mostrando el final reciente")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(FerminCodeDesktopPalette.primary)
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundColor(FerminCodeDesktopPalette.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button {
                Task { await store.refreshDetail() }
            } label: {
                Label("Actualizar", systemImage: "arrow.clockwise")
            }
            .buttonStyle(FerminCodeDesktopButtonStyle())
            .disabled(snapshot.detailLoadState.isLoading)
            .accessibilityHint("Comprueba si el relay ya ofrece más mensajes de esta conversación")
            .accessibilityIdentifier("fermin.desktop.transcript.refreshIncomplete")
        }
        .padding(12)
        .background(FerminCodeDesktopPalette.warning.opacity(0.08))
        .overlay(Rectangle().stroke(FerminCodeDesktopPalette.warning.opacity(0.24)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fermin.desktop.transcript.incompleteBanner")
    }

    private var detailRetryButton: some View {
        Button {
            Task { await store.refreshDetail() }
        } label: {
            Label("Reintentar", systemImage: "arrow.clockwise")
        }
        .buttonStyle(FerminCodeDesktopButtonStyle())
        .disabled(snapshot.detailLoadState.isLoading)
        .accessibilityHint("Vuelve a cargar solamente esta conversación")
        .accessibilityIdentifier("fermin.desktop.transcript.retryDetail")
    }

    private var transcriptPlaceholderAccessibilityIdentifier: String {
        if snapshot.detailLoadState.isLoading { return "fermin.desktop.transcript.loading" }
        if snapshot.detailLoadState.errorMessage != nil {
            return "fermin.desktop.transcript.detailError.empty"
        }
        if snapshot.reportedMessageCount > snapshot.loadedMessageCount {
            return "fermin.desktop.transcript.incomplete"
        }
        return "fermin.desktop.transcript.empty"
    }

    private func messageTailSignature(
        for messages: [FerminCodeDesktopPresentedMessage]
    ) -> String {
        guard let last = messages.last else { return "empty" }
        return "\(messages.count):\(last.id):\(last.message.content.count):\(last.message.status ?? "")"
    }

    private var isProcessing: Bool {
        snapshot.isProcessing
    }

    private func loadEarlierMessages(
        _ proxy: ScrollViewProxy,
        firstVisibleMessageID: String?,
        loadedMessageCount: Int
    ) {
        let expectedSessionInstanceID = snapshot.selectedSessionInstanceID
        let anchor = FerminCodeDesktopTranscriptIdentityPolicy.earlierMessagesAnchorID(
            route: snapshot.selectedRoute,
            firstVisibleMessageID: firstVisibleMessageID
        )
        visibleMessageLimit = FerminCodeDesktopTranscriptWindowPolicy.nextLimit(
            current: visibleMessageLimit,
            total: loadedMessageCount
        )
        guard let anchor else { return }
        DispatchQueue.main.async {
            guard FerminCodeDesktopTranscriptIdentityPolicy.shouldApplyQueuedEarlierMessagesAnchor(
                expectedSessionInstanceID: expectedSessionInstanceID,
                currentSessionInstanceID: store.selectedSessionInstanceID
            ) else { return }
            proxy.scrollTo(anchor, anchor: .top)
        }
    }

    private func scrollToBottom(
        _ proxy: ScrollViewProxy,
        animated: Bool,
        assertLayout: Bool
    ) {
        DispatchQueue.main.async {
            let scroll = {
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
            if animated, !reduceMotion {
                withAnimation(.easeOut(duration: 0.18), scroll)
            } else {
                scroll()
            }
            guard assertLayout else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
        }
    }
}

struct FerminCodeDesktopMessageRow: View, Equatable {
    let store: FerminCodeDesktopStore
    @State private var isImprovedPromptPresented = false
    @State private var promptStatusObservedAt = Date().timeIntervalSince1970
    @State private var promptStatusNow = Date().timeIntervalSince1970
    @State private var promptAttemptStartedAt: TimeInterval?
    let item: FerminCodeDesktopPresentedMessage
    let isRetryingPromptTransform: Bool

    init(
        store: FerminCodeDesktopStore,
        item: FerminCodeDesktopPresentedMessage,
        isRetryingPromptTransform: Bool = false
    ) {
        self.store = store
        self.item = item
        self.isRetryingPromptTransform = isRetryingPromptTransform
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item
            && lhs.isRetryingPromptTransform == rhs.isRetryingPromptTransform
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if isUser { Spacer(minLength: 80) }
            messageContent
                .frame(maxWidth: isUser ? 560 : 680, alignment: .leading)
            if !isUser { Spacer(minLength: 24) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .contextMenu {
            Button {
                copyMessage()
            } label: {
                Label("Copiar mensaje", systemImage: "doc.on.doc")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Copiar mensaje") { copyMessage() }
        .accessibilityIdentifier("fermin.desktop.message.\(item.message.id)")
        .task(id: promptStatusTrackingID) {
            await trackPromptTransformStatus()
        }
        .sheet(isPresented: $isImprovedPromptPresented) {
            if let improvedPrompt {
                FerminCodeDesktopImprovedPromptView(
                    original: originalPrompt,
                    improved: improvedPrompt
                )
            }
        }
    }

    private var messageContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(author.uppercased())
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(1)
                    .foregroundColor(isUser ? .white : FerminCodeDesktopPalette.accent)
                if let timestamp = FerminCodeDesktopTimestamp.label(item.message.timestamp) {
                    Text(timestamp)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(
                            isUser ? .white.opacity(0.88) : FerminCodeDesktopPalette.muted
                        )
                }
                if let delivery = item.delivery {
                    deliveryLabel(delivery)
                }
                Spacer()
            }

            FerminCodeDesktopMessageBody(
                content: item.message.content,
                isUser: isUser,
                isStreaming: item.isStreaming
            )

            if !item.message.imageAttachments.isEmpty {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 120, maximum: 220), spacing: 6)],
                    alignment: .leading,
                    spacing: 6
                ) {
                    ForEach(item.message.imageAttachments) { attachment in
                        Button {
                            guard let path = attachment.path else { return }
                            Task {
                                await store.openRemotePath(
                                    path: path,
                                    name: attachment.name,
                                    mimeType: attachment.mimeType
                                )
                            }
                        } label: {
                            Label(attachment.name, systemImage: "photo")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .buttonStyle(FerminCodeDesktopButtonStyle())
                        .disabled(attachment.path == nil)
                    }
                }
            }

            if improvedPrompt != nil {
                Button {
                    isImprovedPromptPresented = true
                } label: {
                    Label("Ver prompt mejorado", systemImage: "checkmark")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(isUser ? .white : FerminCodeDesktopPalette.accent)
                .frame(minHeight: FerminCodeDesktopMetrics.compactControlHeight)
                .contentShape(Rectangle())
                .help("Abre el texto original y la versión mejorada.")
                .accessibilityIdentifier(
                    "fermin.desktop.message.improvedPrompt.\(item.message.id)"
                )
            }

            switch FerminCodeDesktopPromptTransformPresentation.state(
                status: item.message.transformStatus,
                errorReason: item.message.transformErrorReason,
                hasResult: promptTransformHasResult,
                timestamp: item.message.timestamp,
                observedAt: promptStatusObservedAt,
                attemptStartedAt: promptAttemptStartedAt,
                now: promptStatusNow
            ) {
            case .hidden:
                EmptyView()
            case .pending:
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Mejorando este prompt…")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(
                            isUser ? .white.opacity(0.88) : FerminCodeDesktopPalette.secondary
                        )
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.updatesFrequently)
                .help(FerminCodeDesktopPromptTransformPresentation.ongoingHelp)
                .accessibilityHint(FerminCodeDesktopPromptTransformPresentation.ongoingHelp)
                .accessibilityIdentifier("fermin.desktop.message.promptPending.\(item.message.id)")
            case .reconciling:
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Verificando esta mejora…")
                }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(
                        isUser ? .white.opacity(0.88) : FerminCodeDesktopPalette.secondary
                    )
                    .help(FerminCodeDesktopPromptTransformPresentation.reconciliationHelp)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.updatesFrequently)
                    .accessibilityHint(
                        FerminCodeDesktopPromptTransformPresentation.reconciliationHelp
                    )
                    .accessibilityIdentifier(
                        "fermin.desktop.message.promptReconciling.\(item.message.id)"
                    )
            case .stalled:
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                        .accessibilityHidden(true)
                    Text("La mejora está demorando más de lo esperado.")
                    promptRetryButton(
                        accessibilityIdentifier:
                        "fermin.desktop.message.retryStalledPrompt.\(item.message.id)"
                    )
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(isUser ? .white : FerminCodeDesktopPalette.warning)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(
                    "fermin.desktop.message.promptStalled.\(item.message.id)"
                )
            case .failed:
                HStack(spacing: 8) {
                    Text(promptTransformErrorMessage)
                        .font(.system(size: 10))
                        .foregroundColor(isUser ? .white : FerminCodeDesktopPalette.danger)
                    promptRetryButton(
                        accessibilityIdentifier: "fermin.desktop.message.retryPrompt.\(item.message.id)"
                    )
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("fermin.desktop.message.promptFailed.\(item.message.id)")
            }
        }
        .padding(isUser ? 13 : 0)
        .padding(.leading, isUser ? 0 : 12)
        .background(
            isUser
                ? FerminCodeDesktopPalette.userSurface
                : Color.clear,
            in: RoundedRectangle(
                cornerRadius: isUser ? FerminCodeDesktopPalette.bevel : 0,
                style: .continuous
            )
        )
        .overlay(alignment: .top) {
            if isUser {
                Rectangle()
                    .fill(FerminCodeDesktopPalette.topLight)
                    .frame(height: 0.5)
                    .padding(.horizontal, FerminCodeDesktopPalette.bevel)
            }
        }
        .overlay(alignment: .leading) {
            if !isUser {
                Rectangle()
                    .fill(FerminCodeDesktopPalette.accent)
                    .frame(width: 1.5)
            }
        }
    }

    @ViewBuilder
    private func deliveryLabel(_ delivery: FerminCodeDesktopOptimisticMessage.Delivery) -> some View {
        switch delivery {
        case .sending:
            Text("ENVIANDO")
                .foregroundColor(FerminCodeDesktopPalette.warning)
        case .accepted:
            Text("ACEPTADO")
                .foregroundColor(FerminCodeDesktopPalette.positive)
        case .failed(let reason):
            HStack(spacing: 7) {
                Text("NO ENVIADO")
                    .foregroundColor(FerminCodeDesktopPalette.danger)
                    .accessibilityLabel("No enviado. \(reason)")
                Button {
                    store.recoverFailedComposer(messageID: item.message.id)
                } label: {
                    Label("Recuperar", systemImage: "arrow.uturn.backward")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(isUser ? .white : FerminCodeDesktopPalette.accent)
                .help("Devuelve este mensaje al editor sin borrar el borrador actual.")
                .accessibilityIdentifier("fermin.desktop.message.recover.\(item.message.id)")
            }
        }
    }

    private var isUser: Bool {
        item.message.role.lowercased() == "user"
    }

    private var author: String {
        isUser ? "Vos" : "Fermín"
    }

    private var promptTransformErrorMessage: String {
        FerminCodeDesktopPromptTransformPresentation.failureDetail(
            status: item.message.transformStatus,
            errorReason: item.message.transformErrorReason
        )
    }

    private var promptTransformHasResult: Bool {
        !(item.message.transformedPrompt ?? "").isEmpty
            || !(item.message.improvedPrompt ?? "").isEmpty
    }

    private var improvedPrompt: String? {
        [item.message.transformedPrompt, item.message.improvedPrompt]
            .compactMap { value -> String? in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : trimmed
            }
            .first
    }

    private var originalPrompt: String {
        let original = item.message.originalPrompt?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return original.isEmpty ? item.message.content : original
    }

    private var promptStatusTrackingID: String {
        [
            item.message.transformStatus ?? "",
            item.message.transformErrorReason ?? "",
            promptTransformHasResult ? "result" : "no-result",
            String(item.message.timestamp),
            String(promptAttemptStartedAt ?? 0),
        ].joined(separator: ":")
    }

    private func trackPromptTransformStatus() async {
        promptStatusNow = Date().timeIntervalSince1970
        while !Task.isCancelled {
            let state = FerminCodeDesktopPromptTransformPresentation.state(
                status: item.message.transformStatus,
                errorReason: item.message.transformErrorReason,
                hasResult: promptTransformHasResult,
                timestamp: item.message.timestamp,
                observedAt: promptStatusObservedAt,
                attemptStartedAt: promptAttemptStartedAt,
                now: promptStatusNow
            )
            guard FerminCodeDesktopPromptTransformPresentation.shouldRefreshLocally(state)
            else { return }
            do {
                try await Task.sleep(
                    nanoseconds:
                    FerminCodeDesktopPromptTransformPresentation.localRefreshNanoseconds
                )
            } catch {
                return
            }
            promptStatusNow = Date().timeIntervalSince1970
        }
    }

    private func promptRetryButton(accessibilityIdentifier: String) -> some View {
        Button {
            let startedAt = Date().timeIntervalSince1970
            promptAttemptStartedAt = startedAt
            promptStatusNow = startedAt
            Task {
                let succeeded = await store.retryPromptTransform(messageID: item.message.id)
                if !succeeded, promptAttemptStartedAt == startedAt {
                    promptAttemptStartedAt = nil
                    promptStatusNow = Date().timeIntervalSince1970
                }
            }
        } label: {
            HStack(spacing: 5) {
                if isRetryingPromptTransform {
                    ProgressView().controlSize(.small)
                }
                Text(isRetryingPromptTransform ? "Reintentando…" : "Reintentar")
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 10, weight: .semibold))
        .foregroundColor(isUser ? .white : FerminCodeDesktopPalette.accent)
        .padding(.horizontal, 8)
        .frame(minHeight: FerminCodeDesktopMetrics.compactControlHeight)
        .background(
            isUser
                ? Color.white.opacity(0.14)
                : FerminCodeDesktopPalette.accentSoft
        )
        .contentShape(Rectangle())
        .disabled(isRetryingPromptTransform)
        .opacity(isRetryingPromptTransform ? 0.72 : 1)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private func copyMessage() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.message.content, forType: .string)
    }

}

private struct FerminCodeDesktopImprovedPromptView: View {
    @Environment(\.dismiss) private var dismiss
    let original: String
    let improved: String

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Lector del prompt mejorado")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(FerminCodeDesktopPalette.primary)
                    Text("Compará sin perder el mensaje original")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(FerminCodeDesktopPalette.muted)
                }
                Spacer(minLength: 12)
                Button("Cerrar") { dismiss() }
                    .buttonStyle(FerminCodeDesktopButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("fermin.desktop.improvedPrompt.close")
            }
            .padding(18)

            Rectangle()
                .fill(FerminCodeDesktopPalette.separator)
                .frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    promptSection(title: "ORIGINAL", content: original)
                    promptSection(title: "MEJORADO", content: improved)
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 720, height: 560)
        .background(FerminCodeDesktopPalette.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fermin.desktop.improvedPrompt.reader")
    }

    private func promptSection(title: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            FerminCodeDesktopSectionLabel(text: title)
            Text(content)
                .font(.system(size: 15))
                .foregroundColor(FerminCodeDesktopPalette.primary)
                .lineSpacing(5)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .ferminCodeInsetSurface()
        }
    }
}

struct FerminCodeDesktopMessageBody: View {
    let content: String
    let isUser: Bool
    let isStreaming: Bool

    private var segments: [FerminCodeDesktopMessageContentSegment] {
        FerminCodeDesktopMessageContentPolicy.segments(
            in: content,
            allowsUnclosedFence: isStreaming && !isUser
        )
    }

    var body: some View {
        Group {
            if isStreaming, !isUser {
                Text(verbatim: content)
                    .font(.system(size: 15))
                    .foregroundColor(FerminCodeDesktopPalette.primary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        switch segment {
                        case .markdown(let markdown):
                            markdownText(markdown)
                                .font(.system(size: 15))
                                .foregroundColor(isUser ? .white : FerminCodeDesktopPalette.primary)
                                .lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                        case .heading(let level, let heading):
                            markdownText(heading)
                                .font(.system(size: headingSize(level), weight: .semibold))
                                .foregroundColor(isUser ? .white : FerminCodeDesktopPalette.primary)
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, level == 1 ? 3 : 1)
                                .accessibilityAddTraits(.isHeader)
                        case .list(let items):
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                                        Text(item.marker)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(
                                                isUser
                                                    ? .white.opacity(0.86)
                                                    : FerminCodeDesktopPalette.accent
                                            )
                                            .frame(width: 22, alignment: .trailing)
                                            .accessibilityHidden(true)
                                        markdownText(item.content)
                                            .font(.system(size: 15))
                                            .foregroundColor(
                                                isUser ? .white : FerminCodeDesktopPalette.primary
                                            )
                                            .lineSpacing(4)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .accessibilityElement(children: .combine)
                                    .accessibilityLabel("\(item.marker) \(item.content)")
                                }
                            }
                        case .quote(let quote):
                            HStack(alignment: .top, spacing: 8) {
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(
                                        isUser
                                            ? Color.white.opacity(0.76)
                                            : FerminCodeDesktopPalette.accent
                                    )
                                    .frame(width: 2)
                                    .accessibilityHidden(true)
                                markdownText(quote)
                                    .font(.system(size: 15))
                                    .foregroundColor(
                                        isUser
                                            ? .white.opacity(0.9)
                                            : FerminCodeDesktopPalette.secondary
                                    )
                                    .lineSpacing(4)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("Cita: \(quote)")
                        case .table(let headers, let rows):
                            FerminCodeDesktopMarkdownTable(
                                headers: headers,
                                rows: rows,
                                isUser: isUser
                            )
                        case .code(let language, let code):
                            FerminCodeDesktopCodeBlock(
                                language: language,
                                code: code,
                                isUser: isUser
                            )
                        }
                    }
                }
            }
        }
        // SwiftUI's macOS SelectionOverlay can feed AppKit updates back into
        // LazyVStack measurement while a transcript is changing.  That loop
        // previously pinned the main thread and retained millions of layout
        // allocations.  Message and code-block copy actions remain available
        // without installing one selection overlay per transcript row.
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isStreaming ? .updatesFrequently : [])
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 18
        case 2: return 16.5
        default: return 14.5
        }
    }

    private func markdownText(_ content: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        if let attributed = try? AttributedString(markdown: content, options: options) {
            return Text(attributed)
        }
        return Text(content)
    }
}

private struct FerminCodeDesktopMarkdownTable: View {
    let headers: [String]
    let rows: [[String]]
    let isUser: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(headers.enumerated()), id: \.offset) { index, header in
                    cellText(header)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(primaryText)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                        .overlay(alignment: .trailing) {
                            if index < headers.count - 1 {
                                Rectangle().fill(borderColor).frame(width: 0.5)
                            }
                        }
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityLabel("Columna \(header)")
                }
            }
            .background(headerBackground)

            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.offset) { columnIndex, value in
                        cellText(value)
                            .font(.system(size: 11.5))
                            .foregroundColor(primaryText)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                            .overlay(alignment: .trailing) {
                                if columnIndex < headers.count - 1 {
                                    Rectangle().fill(borderColor).frame(width: 0.5)
                                }
                            }
                            .accessibilityLabel(
                                tableCellAccessibilityLabel(
                                    columnIndex: columnIndex,
                                    value: value
                                )
                            )
                    }
                }
                .background(
                    rowIndex.isMultiple(of: 2)
                        ? rowBackground
                        : Color.clear
                )
                .overlay(alignment: .top) {
                    Rectangle().fill(borderColor).frame(height: 0.5)
                }
            }
        }
        .background(tableBackground)
        .clipShape(RoundedRectangle(cornerRadius: FerminCodeDesktopPalette.bevel))
        .overlay {
            RoundedRectangle(cornerRadius: FerminCodeDesktopPalette.bevel)
                .stroke(borderColor, lineWidth: 0.75)
        }
        .tint(isUser ? .white : FerminCodeDesktopPalette.accent)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tabla, \(headers.count) columnas, \(rows.count) filas")
    }

    private var primaryText: Color {
        isUser ? .white : FerminCodeDesktopPalette.primary
    }

    private var borderColor: Color {
        isUser ? Color.white.opacity(0.18) : FerminCodeDesktopPalette.separator
    }

    private var headerBackground: Color {
        isUser ? Color.white.opacity(0.12) : FerminCodeDesktopPalette.raised
    }

    private var rowBackground: Color {
        isUser ? Color.white.opacity(0.04) : Color.white.opacity(0.025)
    }

    private var tableBackground: Color {
        isUser ? Color.black.opacity(0.08) : FerminCodeDesktopPalette.canvasTop
    }

    private func tableCellAccessibilityLabel(
        columnIndex: Int,
        value: String
    ) -> String {
        guard headers.indices.contains(columnIndex) else { return value }
        return "\(headers[columnIndex]): \(value)"
    }

    private func cellText(_ content: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        if let attributed = try? AttributedString(markdown: content, options: options) {
            return Text(attributed)
        }
        return Text(content)
    }
}

private struct FerminCodeDesktopCodeBlock: View {
    let language: String?
    let code: String
    let isUser: Bool
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(languageLabel)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundColor(codeText.opacity(0.78))
                    .lineLimit(1)
                Spacer()
                Button {
                    copyCode()
                } label: {
                    Label(copied ? "Copiado" : "Copiar", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(codeText.opacity(0.9))
                .frame(minHeight: FerminCodeDesktopMetrics.compactControlHeight)
                .contentShape(Rectangle())
                .help(copied ? "Código copiado" : "Copiar este bloque")
                .accessibilityLabel(copied ? "Código copiado" : "Copiar código")
            }
            .padding(.horizontal, 9)
            .frame(minHeight: 30)

            Rectangle()
                .fill(borderColor)
                .frame(height: 0.5)

            Text(verbatim: code.isEmpty ? " " : code)
                .font(.system(size: 12.5, design: .monospaced))
                .lineSpacing(2.5)
                .foregroundColor(codeText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
        }
        .background(isUser ? Color.black.opacity(0.18) : FerminCodeDesktopPalette.codeSurface)
        .clipShape(RoundedRectangle(cornerRadius: FerminCodeDesktopPalette.bevel, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FerminCodeDesktopPalette.bevel, style: .continuous)
                .stroke(borderColor, lineWidth: 0.75)
        }
        .accessibilityElement(children: .contain)
    }

    private var codeText: Color {
        isUser ? .white : FerminCodeDesktopPalette.primary
    }

    private var languageLabel: String {
        let value = language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "CÓDIGO" : value.uppercased()
    }

    private var borderColor: Color {
        Color.white.opacity(isUser ? 0.16 : 0.07)
    }

    private func copyCode() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copied = false
        }
    }
}

private struct FerminCodeDesktopComposerSendError: View {
    @EnvironmentObject private var store: FerminCodeDesktopStore
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(FerminCodeDesktopPalette.danger)
                .accessibilityHidden(true)
            Text("No se pudo enviar. El borrador quedó intacto.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(FerminCodeDesktopPalette.primary)
                .lineLimit(2)
                .help(message)
            Spacer(minLength: 8)
            Button {
                Task { await store.retryComposerSend() }
            } label: {
                HStack(spacing: 6) {
                    if store.isSending {
                        ProgressView().controlSize(.small)
                    }
                    Text(store.isSending ? "Reintentando…" : "Reintentar")
                }
            }
            .buttonStyle(FerminCodeDesktopButtonStyle())
            .disabled(store.isSending)
            .accessibilityHint("Vuelve a enviar el borrador conservado")
            .accessibilityIdentifier("fermin.desktop.composer.retrySend")
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 36)
        .background(FerminCodeDesktopPalette.danger.opacity(0.10))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(FerminCodeDesktopPalette.danger.opacity(0.30))
                .frame(height: 1)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Error al enviar: \(message)")
        .accessibilityIdentifier("fermin.desktop.composer.sendError")
    }
}

struct FerminCodeDesktopComposer: View {
    @EnvironmentObject private var store: FerminCodeDesktopStore
    @FocusState private var isMessageEditorFocused: Bool
    @State private var isImageDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                attachmentTray
                editorSurface
                HStack(spacing: 6) {
                    attachmentButton
                    promptImproverToggle
                    explainerToggle
                    codeContextToggle

                    if store.isUpdatingSelectedFeatures {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Actualizando funciones")
                    }

                    Spacer(minLength: 8)

                    if let composerStatusLabel {
                        Text(composerStatusLabel)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(composerStatusColor)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(minWidth: 64, maxWidth: 160, alignment: .trailing)
                            .help(composerStatusHelp)
                            .accessibilityIdentifier("fermin.desktop.composer.availability")
                    }

                    sendButton
                }
            }
            .padding(8)
            .ferminCodeInsetSurface()
        }
        .padding(.horizontal, 12)
        .padding(.top, store.composerSendErrorMessage == nil ? 8 : 6)
        .padding(.bottom, 8)
        .background(FerminCodeDesktopPalette.canvas)
        .onAppear { isMessageEditorFocused = true }
        .onChange(of: store.selectedRoute) { _ in
            isMessageEditorFocused = true
        }
        .onChange(of: store.hasPresentedModal) { isPresented in
            guard FerminCodeDesktopComposerFocusPolicy.shouldRestoreAfterModal(
                isModalPresented: isPresented,
                hasSelectedSession: store.selectedRoute != nil
            ) else { return }
            DispatchQueue.main.async {
                isMessageEditorFocused = true
            }
        }
    }

    @ViewBuilder
    private var attachmentTray: some View {
        if !store.attachments.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text("Adjuntos")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(FerminCodeDesktopPalette.secondary)
                    Spacer(minLength: 6)
                    Text("\(store.attachments.count)/\(FerminCodeDesktopAttachmentPolicy.maximumCount)")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(FerminCodeDesktopPalette.muted)
                        .help(attachmentCapacityDescription)
                        .accessibilityLabel(
                            "\(store.attachments.count) de \(FerminCodeDesktopAttachmentPolicy.maximumCount) imágenes"
                        )
                        .accessibilityHint(attachmentCapacityDescription)
                        .accessibilityAddTraits(.updatesFrequently)
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 150, maximum: 250), spacing: 6)],
                    alignment: .leading,
                    spacing: 5
                ) {
                    ForEach(store.attachments) { attachment in
                        HStack(spacing: 5) {
                            Image(systemName: "photo")
                            Text(attachment.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(attachment.name)
                            Text(formattedSize(attachment.data.count))
                                .foregroundColor(FerminCodeDesktopPalette.muted)
                                .fixedSize(horizontal: true, vertical: false)
                            Button {
                                store.removeAttachment(id: attachment.id)
                            } label: {
                                Image(systemName: "xmark")
                                    .frame(width: 20, height: 20)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Quitar \(attachment.name)")
                            .accessibilityLabel("Quitar \(attachment.name)")
                        }
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundColor(FerminCodeDesktopPalette.secondary)
                        .padding(.leading, 7)
                        .padding(.trailing, 3)
                        .frame(maxWidth: .infinity, minHeight: 25, alignment: .leading)
                        .ferminCodeRaisedSurface(fill: FerminCodeDesktopPalette.raised)
                    }
                }
            }
        }
    }

    private var editorSurface: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $store.composerText)
                .font(.system(size: 14))
                .foregroundColor(FerminCodeDesktopPalette.primary)
                .tint(FerminCodeDesktopPalette.accent)
                .environment(\.colorScheme, .dark)
                .ferminComposerScrollBackground()
                .ferminDesktopTextEditorAppearance()
                .background(Color.clear)
                .frame(height: 50)
                .padding(.horizontal, 2)
                .focused($isMessageEditorFocused)
                .onExitCommand { isMessageEditorFocused = false }
                .onPasteCommand(of: [.png, .jpeg, .gif, .webP, .tiff, .image]) { providers in
                    Task { await store.addAttachments(from: providers) }
                }
                .accessibilityLabel("Mensaje")
                .accessibilityHint(
                    "Retorno agrega una línea. Comando Retorno envía. Escape sale del editor. También podés pegar o arrastrar imágenes para adjuntarlas."
                )
                .accessibilityIdentifier("fermin.desktop.composer.text")

            if !composerHasVisibleText {
                Text(composerPlaceholder)
                    .font(.system(size: 14))
                    .foregroundColor(FerminCodeDesktopPalette.muted)
                    .padding(.leading, 4)
                    .padding(.top, 6)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            if isImageDropTargeted {
                Label("Soltá para adjuntar", systemImage: "photo.on.rectangle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(FerminCodeDesktopPalette.accent)
                    .padding(.horizontal, 9)
                    .frame(height: FerminCodeDesktopMetrics.compactControlHeight)
                    .ferminCodeRaisedSurface(fill: FerminCodeDesktopPalette.raised)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(4)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            } else if let composerUsageLabel {
                Text(composerUsageLabel)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(
                        store.composerValidationMessage == nil
                            ? FerminCodeDesktopPalette.warning
                            : FerminCodeDesktopPalette.danger
                    )
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .ferminCodeRaisedSurface(fill: FerminCodeDesktopPalette.raised)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(4)
                    .allowsHitTesting(false)
                    .accessibilityLabel("Tamaño del mensaje: \(composerUsageLabel)")
            }
        }
        .background(isImageDropTargeted ? FerminCodeDesktopPalette.accentSoft : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(editorBorderColor)
                .frame(height: editorBorderWidth)
        }
        .ferminImageDropDestination(
            canAccept: canAcceptImageDrop,
            isTargeted: $isImageDropTargeted
        ) { urls in
            Task { await store.addAttachments(from: urls) }
        }
    }

    private var editorBorderColor: Color {
        if store.composerValidationMessage != nil { return FerminCodeDesktopPalette.danger }
        if isImageDropTargeted || isMessageEditorFocused { return FerminCodeDesktopPalette.accent.opacity(0.78) }
        return FerminCodeDesktopPalette.separator
    }

    private var editorBorderWidth: CGFloat {
        store.composerValidationMessage != nil || isImageDropTargeted || isMessageEditorFocused ? 1 : 0.5
    }

    private var attachmentButton: some View {
        Button(action: chooseImages) {
            Group {
                if store.isAddingAttachments {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "paperclip")
                }
            }
            .frame(width: 24, height: 24)
            .foregroundColor(FerminCodeDesktopPalette.secondary)
            .frame(
                width: FerminCodeDesktopMetrics.iconControlSize,
                height: FerminCodeDesktopMetrics.iconControlSize
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(
            store.isAddingAttachments
                || store.attachments.count >= FerminCodeDesktopAttachmentPolicy.maximumCount
        )
        .help(attachmentButtonHelp)
        .accessibilityLabel("Adjuntar imágenes")
        .accessibilityValue(
            store.isAddingAttachments
                ? "Preparando imágenes"
                : "\(store.attachments.count) de \(FerminCodeDesktopAttachmentPolicy.maximumCount)"
        )
        .accessibilityIdentifier("fermin.desktop.composer.attach")
    }

    private var attachmentButtonHelp: String {
        if store.isAddingAttachments { return "Preparando imágenes…" }
        if store.attachments.count >= FerminCodeDesktopAttachmentPolicy.maximumCount {
            return "Ya adjuntaste el máximo de 10 imágenes"
        }
        return "Adjuntar imágenes PNG, JPEG, GIF o WebP. También podés pegarlas con Comando V."
    }

    private var promptImproverToggle: some View {
        Toggle(isOn: Binding(
            get: { store.selectedFeatures.promptImproverEnabled },
            set: { next in Task { await store.setFeatures(promptImprover: next) } }
        )) {
            featureToggleLabel(
                title: "Mejorar",
                symbol: "sparkles",
                isActive: store.selectedFeatures.promptImproverEnabled
            )
        }
        .toggleStyle(.button)
        .buttonStyle(FerminCodeDesktopFeatureButtonStyle(
            isActive: store.selectedFeatures.promptImproverEnabled
        ))
        .disabled(!canControlFeatures)
        .help(promptImproverHelp)
        .accessibilityLabel("Mejorador de prompts")
        .accessibilityValue(featureAccessibilityValue(store.selectedFeatures.promptImproverEnabled))
        .accessibilityHint(promptImproverHelp)
        .accessibilityIdentifier("fermin.desktop.composer.promptImprover")
    }

    private var explainerToggle: some View {
        Toggle(isOn: Binding(
            get: { store.selectedFeatures.explainerEnabled },
            set: { next in Task { await store.setFeatures(explainer: next) } }
        )) {
            featureToggleLabel(
                title: "Explainer",
                symbol: "text.bubble",
                isActive: store.selectedFeatures.explainerEnabled
            )
        }
        .toggleStyle(.button)
        .buttonStyle(FerminCodeDesktopFeatureButtonStyle(
            isActive: store.selectedFeatures.explainerEnabled
        ))
        .disabled(!canControlFeatures)
        .help(explainerHelp)
        .accessibilityLabel("Explicación de respuestas")
        .accessibilityValue(featureAccessibilityValue(store.selectedFeatures.explainerEnabled))
        .accessibilityHint(explainerHelp)
        .accessibilityIdentifier("fermin.desktop.composer.explainer")
    }

    private var codeContextToggle: some View {
        Toggle(isOn: Binding(
            get: { store.selectedFeatures.codeContextEnabled },
            set: { next in Task { await store.setFeatures(codeContext: next) } }
        )) {
            featureToggleLabel(
                title: "Contexto",
                symbol: "chevron.left.forwardslash.chevron.right",
                isActive: store.selectedFeatures.codeContextEnabled
            )
        }
        .toggleStyle(.button)
        .buttonStyle(FerminCodeDesktopFeatureButtonStyle(
            isActive: store.selectedFeatures.codeContextEnabled
        ))
        .disabled(!canControlFeatures)
        .help(codeContextHelp)
        .accessibilityLabel("Contexto de código")
        .accessibilityValue(featureAccessibilityValue(store.selectedFeatures.codeContextEnabled))
        .accessibilityHint(codeContextHelp)
        .accessibilityIdentifier("fermin.desktop.composer.codeContext")
    }

    private var sendButton: some View {
        Button {
            Task { await store.sendComposer() }
        } label: {
            HStack(spacing: 6) {
                if store.isSending {
                    ProgressView().controlSize(.small).frame(width: 14, height: 14)
                } else {
                    Image(systemName: "arrow.up")
                }
                Text(store.isSending ? "Enviando…" : "Enviar")
            }
        }
        .buttonStyle(FerminCodeDesktopButtonStyle(prominent: true))
        .disabled(!store.canSend)
        .help(sendButtonHelp)
        .accessibilityLabel("Enviar mensaje")
        .accessibilityHint(sendButtonHelp)
        .accessibilityIdentifier("fermin.desktop.composer.send")
    }

    private var canControlFeatures: Bool {
        store.selectedSession?.canControlFeatures != false
    }

    private var canAcceptImageDrop: Bool {
        !store.isAddingAttachments
            && store.attachments.count < FerminCodeDesktopAttachmentPolicy.maximumCount
    }

    private var sendButtonHelp: String {
        if store.isSending { return "Enviando el mensaje…" }
        if store.isAddingAttachments { return "Preparando imágenes…" }
        if let blockingMessage = store.composerBlockingMessage { return blockingMessage }
        if let validationMessage = store.composerValidationMessage { return validationMessage }
        if !composerHasVisibleText, store.attachments.isEmpty {
            return "Escribí un mensaje o adjuntá una imagen."
        }
        return "Enviar (⌘↩)"
    }

    private var composerHasVisibleText: Bool {
        FerminCodeDesktopComposerTextPresentation.hasVisibleContent(
            store.composerText
        )
    }

    private var composerPlaceholder: String {
        store.isSending ? "Prepará el próximo mensaje…" : "Escribí un mensaje…"
    }

    private var composerStatusLabel: String? {
        if store.composerValidationMessage != nil {
            return "Reducí el mensaje para enviar"
        }
        return FerminCodeDesktopComposerStatusPresentation.label(
            isSending: store.isSending,
            isAddingAttachments: store.isAddingAttachments,
            blockingMessage: store.composerBlockingMessage,
            hasDraft: composerHasVisibleText || !store.attachments.isEmpty
        )
    }

    private var composerStatusHelp: String {
        store.composerValidationMessage ?? composerStatusLabel ?? "Estado del editor"
    }

    private var composerStatusColor: Color {
        if store.composerValidationMessage != nil { return FerminCodeDesktopPalette.danger }
        return composerHasActiveStatus
            ? FerminCodeDesktopPalette.warning
            : FerminCodeDesktopPalette.muted
    }

    private var composerHasActiveStatus: Bool {
        store.isSending
            || store.isAddingAttachments
            || store.composerValidationMessage != nil
            || store.composerBlockingMessage != nil
    }

    private var composerUsageLabel: String? {
        FerminCodeDesktopComposerTextPresentation.usageLabel(for: store.composerText)
    }

    private var promptImproverHelp: String {
        FerminCodeDesktopPromptImproverControlPresentation.help(
            canControl: canControlFeatures,
            isEnabled: store.selectedFeatures.promptImproverEnabled,
            variantLabel: store.selectedPromptPreferenceLabel
        )
    }

    private var explainerHelp: String {
        canControlFeatures
            ? "Explicar las respuestas de los próximos mensajes mientras se generan."
            : "Esta sesión no permite cambiar la explicación de respuestas."
    }

    private var codeContextHelp: String {
        canControlFeatures
            ? "Incluir contexto de código en los próximos mensajes."
            : "Esta sesión no permite cambiar el contexto de código."
    }

    private func featureToggleLabel(
        title: String,
        symbol: String,
        isActive: Bool
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(title)
            Image(systemName: "checkmark")
                .font(.system(size: 8, weight: .bold))
                .opacity(isActive ? 1 : 0)
                .accessibilityHidden(true)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func featureAccessibilityValue(_ isActive: Bool) -> String {
        FerminCodeDesktopFeatureControlPresentation.accessibilityValue(
            isEnabled: isActive
        )
    }

    private func chooseImages() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.png, .jpeg, .gif, .webP]
        panel.message = attachmentPickerMessage
        panel.prompt = "Adjuntar"
        if panel.runModal() == .OK {
            Task { await store.addAttachments(from: panel.urls) }
        }
    }

    private func formattedSize(_ byteCount: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }

    private var attachmentPickerMessage: String {
        let remaining = FerminCodeDesktopAttachmentPolicy.remainingCount(
            existingCount: store.attachments.count
        )
        let noun = remaining == 1 ? "imagen" : "imágenes"
        return "Podés adjuntar \(remaining) \(noun) más: PNG, JPEG, GIF o WebP; 20 MiB por archivo."
    }

    private var attachmentCapacityDescription: String {
        FerminCodeDesktopAttachmentPolicy.capacityDescription(
            existingCount: store.attachments.count
        )
    }
}

private extension View {
    @ViewBuilder
    func ferminComposerScrollBackground() -> some View {
        if #available(macOS 13.0, *) {
            scrollContentBackground(.hidden)
        } else {
            self
        }
    }

    @ViewBuilder
    func ferminImageDropDestination(
        canAccept: Bool,
        isTargeted: Binding<Bool>,
        action: @escaping ([URL]) -> Void
    ) -> some View {
        if #available(macOS 13.0, *) {
            dropDestination(for: URL.self) { urls, _ in
                guard canAccept,
                      FerminCodeDesktopAttachmentPolicy.isLocalFileDropPayload(urls)
                else { return false }
                action(urls)
                return true
            } isTargeted: { nextIsTargeted in
                isTargeted.wrappedValue = nextIsTargeted && canAccept
            }
        } else {
            self
        }
    }
}
