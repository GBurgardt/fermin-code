import AppKit
import FerminCore
import SwiftUI

struct FerminCodeDesktopCreateSessionView: View {
    @EnvironmentObject private var store: FerminCodeDesktopStore
    @State private var sessionName = ""
    @State private var projectPath = ""
    @State private var selectedSource = FerminCodeRelaySource.personal
    @State private var isProjectPickerPresented = false
    @FocusState private var focusedField: Field?

    private enum Field {
        case name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Nueva sesión")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(FerminCodeDesktopPalette.primary)
                    Text("CREAR EN \(selectedSource.displayName.uppercased())")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(0.9)
                        .foregroundColor(FerminCodeDesktopPalette.muted)
                }
                Spacer()
                Button(store.isCreatingSession ? "Ocultar" : "Cancelar") {
                    store.isCreatePresented = false
                }
                    .buttonStyle(.plain)
                    .foregroundColor(FerminCodeDesktopPalette.secondary)
                    .keyboardShortcut(.cancelAction)
                    .help(
                        store.isCreatingSession
                            ? "La creación continuará en segundo plano"
                            : "Cancelar la creación"
                    )
                    .accessibilityHint(
                        store.isCreatingSession
                            ? "Cierra esta ventana; la creación continúa."
                            : "Cierra esta ventana sin crear la sesión."
                    )
                    .accessibilityIdentifier("fermin.desktop.create.cancel")
            }

            FerminCodeDesktopSheetError()

            if store.availableCreateSources.count > 1 {
                VStack(alignment: .leading, spacing: 5) {
                    FerminCodeDesktopSectionLabel(text: "Destino")
                    Picker("Destino", selection: $selectedSource) {
                        ForEach(store.availableCreateSources) { source in
                            Text(source.displayName).tag(source)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .disabled(store.isCreatingSession)
                    .accessibilityIdentifier("fermin.desktop.create.source")
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    FerminCodeDesktopSectionLabel(text: "Nombre")
                    Spacer()
                    Text(nameLengthLabel)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(
                            normalizedName.count > FerminCodeDesktopSessionNamePolicy.maximumLength
                                ? FerminCodeDesktopPalette.danger
                                : FerminCodeDesktopPalette.muted
                        )
                        .accessibilityLabel(nameLengthAccessibilityLabel)
                }
                TextField("Ej. Ajustar relay Personal", text: $sessionName)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .ferminCodeInsetSurface()
                    .overlay(
                        RoundedRectangle(cornerRadius: FerminCodeDesktopPalette.bevel)
                            .stroke(
                            nameValidationMessage == nil
                                ? Color.clear
                                : FerminCodeDesktopPalette.danger,
                            lineWidth: 1
                        )
                    )
                    .disabled(store.isCreatingSession)
                    .focused($focusedField, equals: .name)
                    .onSubmit { createIfPossible() }
                    .accessibilityIdentifier("fermin.desktop.create.name")
                Text(
                    nameValidationMessage
                        ?? "Es obligatorio y admite hasta \(FerminCodeDesktopSessionNamePolicy.maximumLength) caracteres."
                )
                    .font(.system(size: 10))
                    .foregroundColor(
                        nameValidationMessage == nil
                            ? FerminCodeDesktopPalette.muted
                            : FerminCodeDesktopPalette.danger
                    )
                    .accessibilityIdentifier("fermin.desktop.create.name.help")
            }

            VStack(alignment: .leading, spacing: 5) {
                FerminCodeDesktopSectionLabel(text: "Proyecto")
                if store.isLoadingProjects {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Cargando proyectos de producción…")
                    }
                    .frame(height: 36)
                } else if store.projects.isEmpty {
                    HStack(spacing: 9) {
                        Image(systemName: "folder.badge.questionmark")
                            .foregroundColor(FerminCodeDesktopPalette.warning)
                        Text("No pudimos cargar los proyectos.")
                            .font(.system(size: 11))
                            .foregroundColor(FerminCodeDesktopPalette.secondary)
                        Spacer()
                        Button("Reintentar") {
                            Task { await store.loadProjects(source: selectedSource) }
                        }
                        .buttonStyle(FerminCodeDesktopButtonStyle())
                        .disabled(store.isCreatingSession)
                        .accessibilityIdentifier("fermin.desktop.create.projects.retry")
                    }
                    .frame(height: 36)
                } else {
                    Button {
                        isProjectPickerPresented.toggle()
                    } label: {
                        HStack(spacing: 10) {
                            Text(selectedProjectDisplayName)
                                .font(.system(size: 14, weight: .regular, design: .monospaced))
                                .foregroundColor(
                                    projectPath.isEmpty
                                        ? FerminCodeDesktopPalette.muted
                                        : FerminCodeDesktopPalette.primary
                                )
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(FerminCodeDesktopPalette.secondary)
                        }
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .contentShape(Rectangle())
                        .ferminCodeInsetSurface()
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .disabled(store.isCreatingSession)
                    .accessibilityLabel("Proyecto")
                    .accessibilityValue(selectedProjectDisplayName)
                    .accessibilityIdentifier("fermin.desktop.create.project")
                    .popover(isPresented: $isProjectPickerPresented, arrowEdge: .bottom) {
                        ScrollView {
                            VStack(spacing: 2) {
                                ForEach(store.projects) { project in
                                    Button {
                                        projectPath = project.path
                                        isProjectPickerPresented = false
                                    } label: {
                                        HStack(spacing: 10) {
                                            Text(project.name)
                                                .font(.system(size: 12, design: .monospaced))
                                                .foregroundColor(FerminCodeDesktopPalette.primary)
                                                .lineLimit(1)
                                            Spacer(minLength: 12)
                                            if project.path == projectPath {
                                                Image(systemName: "checkmark")
                                                    .font(.system(size: 10, weight: .bold))
                                                    .foregroundColor(FerminCodeDesktopPalette.accent)
                                            }
                                        }
                                        .padding(.horizontal, 10)
                                        .frame(maxWidth: .infinity, minHeight: 32)
                                        .contentShape(Rectangle())
                                        .background(
                                            project.path == projectPath
                                                ? FerminCodeDesktopPalette.raised
                                                : Color.clear
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(project.name)
                                    .accessibilityValue(
                                        project.path == projectPath ? "Seleccionado" : ""
                                    )
                                }
                            }
                            .padding(8)
                        }
                        .frame(width: 300)
                        .frame(maxHeight: 280)
                        .background(FerminCodeDesktopPalette.canvas)
                    }
                }
            }

            Spacer()

            HStack(alignment: .center, spacing: 12) {
                Text(creationProgressDescription)
                    .font(.system(size: 10.5))
                    .foregroundColor(FerminCodeDesktopPalette.muted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button {
                    createIfPossible()
                } label: {
                    HStack(spacing: 7) {
                        if store.isCreatingSession {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityIdentifier("fermin.desktop.create.progress")
                        }
                        Text(creationButtonTitle)
                    }
                }
                .buttonStyle(FerminCodeDesktopButtonStyle(prominent: true))
                .disabled(!canConfirmCreation)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel(creationButtonTitle)
                .help(creationConfirmHelp)
                .accessibilityHint(creationConfirmHelp)
                .accessibilityIdentifier("fermin.desktop.create.confirm")
            }
        }
        .padding(18)
        .frame(
            width: 500,
            height: (store.errorMessage == nil ? 320 : 368)
                + (store.availableCreateSources.count > 1 ? 52 : 0)
        )
        .background(FerminCodeDesktopPalette.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fermin.desktop.create.sheet")
        .onAppear {
            selectedSource = store.preferredCreateSource ?? .personal
            Task { await store.loadProjects(source: selectedSource) }
            if projectPath.isEmpty { projectPath = store.projects.first?.path ?? "" }
            DispatchQueue.main.async { focusedField = .name }
        }
        .onChange(of: selectedSource) { source in
            projectPath = ""
            Task { await store.loadProjects(source: source) }
        }
        .onChange(of: store.projects) { projects in
            if !projects.contains(where: { $0.path == projectPath }) {
                projectPath = projects.first?.path ?? ""
            }
        }
    }

    private var normalizedName: String {
        FerminCodeDesktopSessionNamePolicy.normalized(sessionName)
    }

    private var selectedProjectDisplayName: String {
        guard !projectPath.isEmpty else { return "Elegí un proyecto" }
        return store.projects.first(where: { $0.path == projectPath })?.name
            ?? URL(fileURLWithPath: projectPath).lastPathComponent
    }

    private var creationButtonTitle: String {
        switch store.creationPhase {
        case .idle: return "Crear sesión"
        case .submitting: return "Enviando…"
        case .waitingForConfirmation: return "Preparando…"
        }
    }

    private var creationProgressDescription: String {
        switch store.creationPhase {
        case .idle:
            return "Se inicia con Sol · MAX y se abre automáticamente cuando el servidor confirma que está lista."
        case .submitting:
            return "Enviando la solicitud a \(selectedSource.displayName). Podés ocultar esta ventana sin interrumpirla."
        case .waitingForConfirmation:
            return "\(selectedSource.displayName) aceptó la solicitud. Preparando la sesión; se abrirá apenas esté lista. Podés ocultar esta ventana."
        }
    }

    private var canConfirmCreation: Bool {
        FerminCodeDesktopCreateFormPolicy.canConfirm(
            name: sessionName,
            projectPath: projectPath,
            isCreating: store.isCreatingSession
        )
    }

    private var creationConfirmHelp: String {
        FerminCodeDesktopCreateFormPolicy.confirmHelp(
            name: sessionName,
            projectPath: projectPath,
            isLoadingProjects: store.isLoadingProjects,
            creationPhase: store.creationPhase
        )
    }

    private var nameLengthLabel: String {
        "\(normalizedName.count)/\(FerminCodeDesktopSessionNamePolicy.maximumLength)"
    }

    private var nameLengthAccessibilityLabel: String {
        "\(normalizedName.count) de \(FerminCodeDesktopSessionNamePolicy.maximumLength) caracteres"
    }

    private var nameValidationMessage: String? {
        guard !sessionName.isEmpty else { return nil }
        return FerminCodeDesktopSessionNamePolicy.validationMessage(for: sessionName)
    }

    private func createIfPossible() {
        guard !store.isCreatingSession,
              !projectPath.isEmpty,
              FerminCodeDesktopSessionNamePolicy.isValid(sessionName) else { return }
        Task {
            _ = await store.createSession(
                projectPath: projectPath,
                name: sessionName,
                source: selectedSource
            )
        }
    }
}

struct FerminCodeDesktopCredentialsView: View {
    @EnvironmentObject private var store: FerminCodeDesktopStore
    @Environment(\.dismiss) private var dismiss
    @State private var personalToken = ""
    @State private var pukyToken = ""
    @State private var selectedVariant = FerminRelayPromptImproverVariant.standard
    @State private var hasEditedPromptVariant = false
    @State private var pendingCredentialDeletion: FerminCodeRelaySource?
    @State private var showsBootstrapHelp = false
    @FocusState private var focusedCredential: FerminCodeRelaySource?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ajustes")
                        .font(.system(size: 20, weight: .semibold))
                    Text("Tokens en Keychain y preferencias del mejorador.")
                        .font(.system(size: 11))
                        .foregroundColor(FerminCodeDesktopPalette.muted)
                }
                Spacer()
                Button("Cerrar") {
                    store.isCredentialsPresented = false
                    dismiss()
                }
                    .buttonStyle(FerminCodeDesktopButtonStyle())
                    .accessibilityIdentifier("fermin.desktop.credentials.close")
            }
            .padding(.bottom, 18)

            FerminCodeDesktopSheetError()
                .padding(.bottom, store.errorMessage == nil ? 0 : 12)

            ScrollView {
                VStack(spacing: 14) {
                    credentialSection(
                        source: .personal,
                        token: $personalToken,
                        endpoint: FerminCodeRelaySource.personalProductionURLString
                    )
                    credentialSection(
                        source: .puky,
                        token: $pukyToken,
                        endpoint: FerminCodeRelaySource.pukyProductionURLString
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        FerminCodeDesktopSectionLabel(text: "Mejora de prompt")
                        HStack {
                            Picker("Variante", selection: promptVariantBinding) {
                                Text("Estándar").tag(FerminRelayPromptImproverVariant.standard)
                                Text("Motivacional").tag(FerminRelayPromptImproverVariant.motivational)
                            }
                            .frame(width: 180)
                            .disabled(isApplyingPromptPreference)
                            .accessibilityIdentifier("fermin.desktop.preference.prompt")
                            Text("Destino: \(store.profile.displayName) · actual: \(store.promptPreferenceLabel)")
                                .font(.system(size: 10))
                                .foregroundColor(FerminCodeDesktopPalette.muted)
                            Spacer()
                            Button {
                                Task { _ = await store.setPromptPreference(selectedVariant) }
                            } label: {
                                HStack(spacing: 6) {
                                    if isApplyingPromptPreference {
                                        ProgressView().controlSize(.small)
                                    }
                                    Text(isApplyingPromptPreference ? "Aplicando…" : "Aplicar")
                                }
                            }
                            .buttonStyle(FerminCodeDesktopButtonStyle())
                            .disabled(
                                isApplyingPromptPreference || selectedPromptPreferenceIsCurrent
                            )
                            .help(promptPreferenceApplyHelp)
                            .accessibilityHint(promptPreferenceApplyHelp)
                            .accessibilityIdentifier("fermin.desktop.preference.apply")
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(FerminCodeDesktopPromptPreferencePresentation.scopeHelp)
                                .foregroundColor(FerminCodeDesktopPalette.secondary)
                            Text(
                                FerminCodeDesktopPromptPreferencePresentation.persistenceHelp(
                                    profile: store.profile
                                )
                            )
                            .foregroundColor(FerminCodeDesktopPalette.muted)
                        }
                        .font(.system(size: 10))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("fermin.desktop.preference.scope")
                    }
                    .padding(14)
                    .background(FerminCodeDesktopPalette.raised)
                    .overlay(Rectangle().stroke(FerminCodeDesktopPalette.separator, lineWidth: 1))

                    DisclosureGroup(isExpanded: $showsBootstrapHelp) {
                        Text("Colocá `bootstrap-token`, `bootstrap-token-personal` o `bootstrap-token-puky` con permisos 0600 dentro de Application Support del contenedor. Al iniciar, Fermín Code lo copia a Keychain y elimina el archivo; el valor nunca se registra ni se muestra.")
                            .font(.system(size: 10))
                            .foregroundColor(FerminCodeDesktopPalette.secondary)
                            .textSelection(.enabled)
                            .padding(.top, 8)
                    } label: {
                        Label("Importar token desde archivo (avanzado)", systemImage: "lock.shield.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(FerminCodeDesktopPalette.secondary)
                    }
                    .padding(12)
                    .background(FerminCodeDesktopPalette.raised)
                    .overlay(Rectangle().stroke(FerminCodeDesktopPalette.separator, lineWidth: 1))
                    .accessibilityIdentifier("fermin.desktop.credentials.bootstrapHelp")
                }
            }
        }
        .padding(22)
        .frame(width: 660, height: 590)
        .background(FerminCodeDesktopPalette.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fermin.desktop.credentials.sheet")
        .alert(
            "¿Eliminar el token de \(pendingCredentialDeletion?.displayName ?? "este equipo")?",
            isPresented: Binding(
                get: { pendingCredentialDeletion != nil },
                set: { if !$0 { pendingCredentialDeletion = nil } }
            )
        ) {
            Button("Cancelar", role: .cancel) {
                pendingCredentialDeletion = nil
            }
            Button("Eliminar token", role: .destructive) {
                guard let source = pendingCredentialDeletion else { return }
                pendingCredentialDeletion = nil
                Task {
                    if await store.clearCredential(for: source) {
                        switch source {
                        case .personal: personalToken = ""
                        case .puky: pukyToken = ""
                        }
                    }
                }
            }
        } message: {
            Text("Fermín Code dejará de conectarse a ese relay hasta que guardes otro token.")
        }
        .onAppear {
            syncPromptVariantIfUntouched()
            Task {
                await store.loadPromptPreferences()
                syncPromptVariantIfUntouched()
            }
            DispatchQueue.main.async {
                focusFirstMissingCredentialIfAppropriate()
            }
        }
        .onChange(of: store.credentialPresence) { _ in
            focusFirstMissingCredentialIfAppropriate()
        }
    }

    private var isApplyingPromptPreference: Bool {
        store.activeMutations.contains("prompt-preference")
    }

    private var selectedPromptPreferenceIsCurrent: Bool {
        store.profile.sources.allSatisfy {
            store.promptPreferences[$0]?.variant == selectedVariant
        }
    }

    private var promptPreferenceApplyHelp: String {
        if isApplyingPromptPreference { return "Aplicando la preferencia…" }
        if selectedPromptPreferenceIsCurrent {
            return "La preferencia ya está aplicada en \(store.profile.displayName)."
        }
        return "Aplicar en \(store.profile.displayName)"
    }

    private var promptVariantBinding: Binding<FerminRelayPromptImproverVariant> {
        Binding(
            get: { selectedVariant },
            set: { next in
                hasEditedPromptVariant = true
                selectedVariant = next
            }
        )
    }

    private func syncPromptVariantIfUntouched() {
        guard !hasEditedPromptVariant,
              let current = FerminCodeDesktopPromptPreferenceSelectionPolicy.commonVariant(
                  profile: store.profile,
                  preferences: store.promptPreferences
              ) else { return }
        selectedVariant = current
    }

    private func focusFirstMissingCredentialIfAppropriate() {
        var unsavedSources = Set<FerminCodeRelaySource>()
        if !personalToken.isEmpty { unsavedSources.insert(.personal) }
        if !pukyToken.isEmpty { unsavedSources.insert(.puky) }
        focusedCredential = FerminCodeDesktopCredentialFocusPolicy.preferredSource(
            presence: store.credentialPresence,
            current: focusedCredential,
            unsavedSources: unsavedSources
        )
    }

    private func credentialSection(
        source: FerminCodeRelaySource,
        token: Binding<String>,
        endpoint: String
    ) -> some View {
        let isSaving = store.activeMutations.contains("credential-save-\(source.rawValue)")
        let isDeleting = store.activeMutations.contains("credential-delete-\(source.rawValue)")
        let isBusy = isSaving || isDeleting
        let isConfigured = store.credentialPresence[source] == true
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                FerminCodeDesktopSectionLabel(text: source.displayName)
                Spacer()
                Label(
                    isConfigured ? "Configurado" : "Sin configurar",
                    systemImage: isConfigured
                        ? "checkmark.circle.fill"
                        : "exclamationmark.circle"
                )
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(
                    isConfigured
                        ? FerminCodeDesktopPalette.positive
                        : FerminCodeDesktopPalette.warning
                )
            }
            Text(endpoint)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(FerminCodeDesktopPalette.muted)
                .textSelection(.enabled)
            Text(isConfigured ? "Reemplazar token" : "Token")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(FerminCodeDesktopPalette.secondary)
            HStack(spacing: 8) {
                SecureField(
                    isConfigured ? "Pegá un token para reemplazarlo" : "Pegá el token",
                    text: token
                )
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(FerminCodeDesktopPalette.composer)
                    .overlay(Rectangle().stroke(FerminCodeDesktopPalette.separator, lineWidth: 1))
                    .disabled(isBusy)
                    .focused($focusedCredential, equals: source)
                    .onSubmit {
                        saveCredential(token, for: source, isBusy: isBusy)
                    }
                    .accessibilityLabel(
                        isConfigured
                            ? "Reemplazar token de \(source.displayName)"
                            : "Token de \(source.displayName)"
                    )
                    .accessibilityHint("Podés pegarlo desde un gestor de contraseñas.")
                    .accessibilityIdentifier("fermin.desktop.credentials.\(source.rawValue).token")
                Button {
                    saveCredential(token, for: source, isBusy: isBusy)
                } label: {
                    HStack(spacing: 6) {
                        if isSaving {
                            ProgressView().controlSize(.small)
                        }
                        Text(isSaving ? "Guardando…" : "Guardar")
                    }
                }
                .buttonStyle(FerminCodeDesktopButtonStyle(prominent: true))
                .disabled(!FerminCodeDesktopCredentialActionPolicy.canSave(
                    token: token.wrappedValue,
                    isSaving: isSaving,
                    isDeleting: isDeleting
                ))
                .help(FerminCodeDesktopCredentialActionPolicy.saveHelp(
                    token: token.wrappedValue,
                    isConfigured: isConfigured,
                    isSaving: isSaving,
                    isDeleting: isDeleting
                ))
                .accessibilityHint(FerminCodeDesktopCredentialActionPolicy.saveHelp(
                    token: token.wrappedValue,
                    isConfigured: isConfigured,
                    isSaving: isSaving,
                    isDeleting: isDeleting
                ))
                .accessibilityIdentifier("fermin.desktop.credentials.\(source.rawValue).save")
                if isConfigured {
                    Button {
                        pendingCredentialDeletion = source
                    } label: {
                        HStack(spacing: 6) {
                            if isDeleting {
                                ProgressView().controlSize(.small)
                            }
                            Text(isDeleting ? "Eliminando…" : "Eliminar")
                        }
                    }
                    .buttonStyle(FerminCodeDesktopButtonStyle())
                    .disabled(isBusy)
                    .help("Eliminar el token guardado de \(source.displayName)")
                    .accessibilityIdentifier("fermin.desktop.credentials.\(source.rawValue).delete")
                }
            }
        }
        .padding(14)
        .background(FerminCodeDesktopPalette.raised)
        .overlay(Rectangle().stroke(FerminCodeDesktopPalette.separator, lineWidth: 1))
    }

    private func saveCredential(
        _ token: Binding<String>,
        for source: FerminCodeRelaySource,
        isBusy: Bool
    ) {
        guard !isBusy,
              !token.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        let value = token.wrappedValue
        Task {
            if await store.saveCredential(value, for: source) {
                token.wrappedValue = ""
            }
        }
    }
}

struct FerminCodeDesktopHistoryView: View {
    @EnvironmentObject private var store: FerminCodeDesktopStore
    @State private var query = ""
    @State private var state = FerminRelayHistoryState.all
    @State private var sort = FerminRelayHistorySort.recent
    @State private var isScopeHelpPresented = false
    @State private var isStatePickerPresented = false
    @State private var isSortPickerPresented = false
    @State private var historyRefreshTask: Task<Void, Never>?
    @FocusState private var isHistorySearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Historial")
                        .font(.system(size: 20, weight: .semibold))
                    HStack(spacing: 5) {
                        Text(historySummary)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(FerminCodeDesktopPalette.muted)
                        Button {
                            isScopeHelpPresented.toggle()
                        } label: {
                            Image(systemName: "info.circle")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(FerminCodeDesktopPalette.accent)
                        }
                        .buttonStyle(.plain)
                        .help("Qué incluye este historial")
                        .accessibilityLabel("Qué incluye este historial")
                        .accessibilityIdentifier("fermin.desktop.history.scopeHelp")
                        .popover(isPresented: $isScopeHelpPresented, arrowEdge: .bottom) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Historial de Fermín Code")
                                    .font(.system(size: 13, weight: .semibold))
                                Text("Incluye las sesiones creadas o reanudadas mediante Fermín Code y sincronizadas por los relays Rust. El historial global de Codex no se importa.")
                                    .font(.system(size: 11))
                                    .foregroundColor(FerminCodeDesktopPalette.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(14)
                            .frame(width: 290)
                            .background(FerminCodeDesktopPalette.canvas)
                        }
                    }
                }
                Spacer()
                Button("Cerrar") { store.isHistoryPresented = false }
                    .buttonStyle(.plain)
                    .foregroundColor(FerminCodeDesktopPalette.secondary)
                    .accessibilityIdentifier("fermin.desktop.history.close")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            if let message = store.historyLoadState.partialMessage {
                FerminCodeDesktopHistoryStatusBanner(
                    message: message,
                    isRetrying: store.isLoadingHistory,
                    onRetry: search
                )
                    .padding(.horizontal, 22)
                    .padding(.bottom, 12)
            }

            HStack(spacing: 9) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(FerminCodeDesktopPalette.muted)
                    TextField("Buscar por nombre, proyecto o contenido", text: $query)
                        .textFieldStyle(.plain)
                        .focused($isHistorySearchFocused)
                        .accessibilityIdentifier("fermin.desktop.history.search")
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(FerminCodeDesktopPalette.muted)
                        .help("Borrar búsqueda")
                        .accessibilityLabel("Borrar búsqueda del historial")
                        .accessibilityIdentifier("fermin.desktop.history.search.clear")
                    }
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .ferminCodeInsetSurface()
                Button {
                    isStatePickerPresented.toggle()
                } label: {
                    historyFilterLabel(title: historyStateFilterLabel)
                        .frame(width: 126, height: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Estado")
                .accessibilityValue(historyStateFilterLabel)
                .accessibilityIdentifier("fermin.desktop.history.state")
                .popover(isPresented: $isStatePickerPresented, arrowEdge: .bottom) {
                    historyStatePicker
                }

                Button {
                    isSortPickerPresented.toggle()
                } label: {
                    historyFilterLabel(title: historySortFilterLabel)
                        .frame(width: 146, height: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Orden")
                .accessibilityValue(historySortFilterLabel)
                .accessibilityIdentifier("fermin.desktop.history.sort")
                .popover(isPresented: $isSortPickerPresented, arrowEdge: .bottom) {
                    historySortPicker
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 10)

            Rectangle().fill(FerminCodeDesktopPalette.separator).frame(height: 0.5)

            if store.isLoadingHistory, store.historyItems.isEmpty {
                Spacer()
                ProgressView("Cargando historial…")
                Spacer()
            } else if let message = store.historyLoadState.failureMessage,
                      store.historyItems.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(FerminCodeDesktopPalette.danger)
                        .accessibilityHidden(true)
                    Text(message)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(FerminCodeDesktopPalette.secondary)
                    Text("Reintentá sin perder la búsqueda ni los filtros actuales.")
                        .font(.system(size: 11))
                        .foregroundColor(FerminCodeDesktopPalette.muted)
                    Button("Reintentar") { search() }
                        .buttonStyle(FerminCodeDesktopButtonStyle())
                        .disabled(store.isLoadingHistory)
                        .accessibilityIdentifier("fermin.desktop.history.retry")
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Error: \(message). Reintentá sin perder los filtros actuales.")
                .accessibilityIdentifier("fermin.desktop.history.error")
                Spacer()
            } else if store.historyItems.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Text(hasActiveHistoryFilters ? "No hay coincidencias" : "No hay sesiones de Fermín Code")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(FerminCodeDesktopPalette.secondary)
                    Text(
                        hasActiveHistoryFilters
                            ? "Probá con otra búsqueda o cambiá el filtro de estado."
                            : "Las sesiones globales de Codex no se importan."
                    )
                        .font(.system(size: 11))
                        .foregroundColor(FerminCodeDesktopPalette.muted)
                    if hasActiveHistoryFilters {
                        Button("Limpiar filtros") {
                            clearFilters()
                        }
                        .buttonStyle(FerminCodeDesktopButtonStyle())
                        .accessibilityIdentifier("fermin.desktop.history.clearFilters")
                    }
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(store.historyItems) { sourcedItem in
                            historyRow(sourcedItem)
                        }
                    }
                    .padding(10)
                }
            }
        }
        .frame(width: 740, height: 580)
        .background(FerminCodeDesktopPalette.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fermin.desktop.history.sheet")
        .onExitCommand {
            switch FerminCodeDesktopHistoryEscapePolicy.action(
                queryIsEmpty: query.isEmpty,
                isSearchFocused: isHistorySearchFocused
            ) {
            case .clearQuery:
                query = ""
            case .resignFocus:
                isHistorySearchFocused = false
            case .dismissSheet:
                store.isHistoryPresented = false
            }
        }
        .task(id: historySearchID) {
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await store.loadHistory(text: query, state: state, sort: sort)
        }
        .onDisappear {
            historyRefreshTask?.cancel()
            historyRefreshTask = nil
            store.invalidateHistoryRequestForLifecycle()
        }
    }

    private func historyRow(_ sourcedItem: FerminCodeDesktopSourcedHistoryItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(sourcedItem.item.sessionName.isEmpty ? "Sesión sin nombre" : sourcedItem.item.sessionName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(FerminCodeDesktopPalette.primary)
                    Text(sourcedItem.source.displayName.uppercased())
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(FerminCodeDesktopPalette.accent)
                    Label(
                        FerminCodeDesktopHistoryPresentation.stateLabel(sourcedItem.item.state),
                        systemImage: FerminCodeDesktopHistoryPresentation.stateSymbol(
                            sourcedItem.item.state
                        )
                    )
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(historyStateColor(sourcedItem.item.state))
                }
                if !sourcedItem.item.preview.isEmpty {
                    Text(sourcedItem.item.preview)
                        .font(.system(size: 11.5))
                        .foregroundColor(FerminCodeDesktopPalette.secondary)
                        .lineLimit(1)
                }
                Text(sourcedItem.item.projectName)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(FerminCodeDesktopPalette.muted)
            }
            Spacer()
            if let active = activeSession(for: sourcedItem) {
                Button("Abrir") {
                    store.selectSession(active)
                    store.isHistoryPresented = false
                }
                .buttonStyle(FerminCodeDesktopButtonStyle())
            } else if sourcedItem.item.canResume {
                Button {
                    Task { _ = await store.resumeHistoryItem(sourcedItem) }
                } label: {
                    HStack(spacing: 6) {
                        if isResuming(sourcedItem) {
                            ProgressView().controlSize(.small)
                        }
                        Text(isResuming(sourcedItem) ? "Reanudando…" : "Reanudar")
                    }
                }
                .buttonStyle(FerminCodeDesktopButtonStyle(prominent: true))
                .disabled(store.activeMutations.contains("resume"))
                .accessibilityIdentifier("fermin.desktop.history.resume.\(sourcedItem.item.id)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .ferminCodeRaisedSurface(fill: FerminCodeDesktopPalette.surface)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fermin.desktop.history.row.\(sourcedItem.source.rawValue).\(sourcedItem.item.id)")
    }

    private func historyFilterLabel(title: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(FerminCodeDesktopPalette.secondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(FerminCodeDesktopPalette.muted)
        }
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .ferminCodeRaisedSurface(fill: FerminCodeDesktopPalette.raised)
    }

    private var historyStatePicker: some View {
        VStack(spacing: 2) {
            ForEach(
                [FerminRelayHistoryState.all, .active, .archived],
                id: \.self
            ) { option in
                Button {
                    state = option
                    isStatePickerPresented = false
                } label: {
                    historyPickerRow(
                        title: historyStateLabel(option),
                        isSelected: state == option
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .frame(width: 150)
        .background(FerminCodeDesktopPalette.canvas)
    }

    private var historySortPicker: some View {
        VStack(spacing: 2) {
            ForEach(
                [FerminRelayHistorySort.recent, .relevance, .name],
                id: \.self
            ) { option in
                Button {
                    sort = option
                    isSortPickerPresented = false
                } label: {
                    historyPickerRow(
                        title: historySortLabel(option),
                        isSelected: sort == option
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .frame(width: 170)
        .background(FerminCodeDesktopPalette.canvas)
    }

    private func historyPickerRow(title: String, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundColor(FerminCodeDesktopPalette.primary)
            Spacer(minLength: 12)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(FerminCodeDesktopPalette.accent)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 30)
        .contentShape(Rectangle())
        .background(isSelected ? FerminCodeDesktopPalette.raised : Color.clear)
    }

    private var historyStateFilterLabel: String {
        historyStateLabel(state)
    }

    private func historyStateLabel(_ value: FerminRelayHistoryState) -> String {
        switch value {
        case .all: return "Todo"
        case .active: return "Activas"
        case .archived: return "Archivadas"
        case .unknown: return "Desconocido"
        }
    }

    private var historySortFilterLabel: String {
        historySortLabel(sort)
    }

    private func historySortLabel(_ value: FerminRelayHistorySort) -> String {
        switch value {
        case .recent: return "Recientes"
        case .relevance: return "Relevancia"
        case .name: return "Nombre"
        case .unknown: return "Desconocido"
        }
    }

    private func activeSession(
        for sourcedItem: FerminCodeDesktopSourcedHistoryItem
    ) -> FerminCodeRelaySourcedSession? {
        guard let windowID = sourcedItem.item.windowID else { return nil }
        return store.sourcedSessions.first {
            $0.source == sourcedItem.source && $0.session.windowID == windowID
        }
    }

    private func search() {
        let requestedQuery = query
        let requestedState = state
        let requestedSort = sort
        historyRefreshTask?.cancel()
        historyRefreshTask = Task { @MainActor in
            guard !Task.isCancelled, store.isHistoryPresented else { return }
            await store.loadHistory(
                text: requestedQuery,
                state: requestedState,
                sort: requestedSort
            )
        }
    }

    private func clearFilters() {
        query = ""
        state = .all
        sort = .recent
    }

    private var hasActiveHistoryFilters: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state != .all
    }

    private var historySummary: String {
        switch store.historyLoadState {
        case .loading where store.historyItems.isEmpty:
            return "CARGANDO HISTORIAL · \(store.profile.displayName.uppercased())"
        case .revalidating:
            return "\(store.historyTotal) SESIONES · \(store.profile.displayName.uppercased()) · ACTUALIZANDO"
        case .failed where store.historyItems.isEmpty:
            return "HISTORIAL NO DISPONIBLE · \(store.profile.displayName.uppercased())"
        default:
            return "\(store.historyTotal) SESIONES · \(store.profile.displayName.uppercased()) · SÓLO FERMÍN CODE"
        }
    }

    private var historySearchID: String {
        [
            query,
            String(describing: state),
            String(describing: sort),
            store.profile.rawValue,
        ].joined(separator: "|")
    }

    private func isResuming(_ sourcedItem: FerminCodeDesktopSourcedHistoryItem) -> Bool {
        store.activeMutations.contains(
            FerminCodeDesktopHistoryPresentation.resumeMutationKey(
                source: sourcedItem.source,
                itemID: sourcedItem.item.id
            )
        )
    }

    private func historyStateColor(_ state: FerminRelayHistoryState) -> Color {
        switch state {
        case .active: return FerminCodeDesktopPalette.positive
        case .archived: return FerminCodeDesktopPalette.secondary
        case .all, .unknown: return FerminCodeDesktopPalette.muted
        }
    }
}

private struct FerminCodeDesktopHistoryStatusBanner: View {
    let message: String
    let isRetrying: Bool
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(FerminCodeDesktopPalette.danger)
                .accessibilityHidden(true)
            Text(message)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(FerminCodeDesktopPalette.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            Button {
                onRetry()
            } label: {
                HStack(spacing: 5) {
                    if isRetrying {
                        ProgressView().controlSize(.small)
                    }
                    Text(isRetrying ? "Reintentando…" : "Reintentar")
                }
            }
            .buttonStyle(FerminCodeDesktopButtonStyle())
            .disabled(isRetrying)
            .accessibilityIdentifier("fermin.desktop.history.partialRetry")
        }
        .padding(9)
        .background(FerminCodeDesktopPalette.danger.opacity(0.10))
        .overlay(Rectangle().stroke(FerminCodeDesktopPalette.danger.opacity(0.32)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Aviso: \(message)")
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier("fermin.desktop.history.partialError")
    }
}

struct FerminCodeDesktopSubagentView: View {
    @EnvironmentObject private var store: FerminCodeDesktopStore
    @FocusState private var focusedField: Field?

    private enum Field {
        case name
        case task
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Crear subagente Codex")
                        .font(.system(size: 19, weight: .semibold))
                    Text(
                        isCreating
                            ? "La creación continúa aunque ocultes esta ventana."
                            : "Hereda el proyecto y la sesión de origen."
                    )
                        .font(.system(size: 11))
                        .foregroundColor(FerminCodeDesktopPalette.muted)
                }
                Spacer()
                Button(isCreating ? "Ocultar" : "Cancelar") {
                    if !isCreating { store.discardSubagentDraft() }
                    store.isSubagentPresented = false
                }
                    .buttonStyle(.plain)
                    .foregroundColor(FerminCodeDesktopPalette.secondary)
                    .keyboardShortcut(.cancelAction)
                    .help(
                        isCreating
                            ? "La tarea y la creación quedan guardadas"
                            : "Descartar esta tarea"
                    )
            }
            FerminCodeDesktopSheetError()
            HStack {
                FerminCodeDesktopSectionLabel(text: "Nombre opcional")
                Spacer()
                Text(
                    "\(normalizedSubagentName.count)/\(FerminCodeDesktopSessionNamePolicy.maximumLength)"
                )
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(
                        subagentNameValidationMessage == nil
                            ? FerminCodeDesktopPalette.muted
                            : FerminCodeDesktopPalette.danger
                    )
                    .accessibilityLabel(
                        "\(normalizedSubagentName.count) de \(FerminCodeDesktopSessionNamePolicy.maximumLength) caracteres"
                    )
            }
            TextField("Ej. Auditar pruebas", text: $store.subagentDisplayNameDraft)
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .frame(height: 38)
                .ferminCodeInsetSurface()
                .overlay(
                    RoundedRectangle(cornerRadius: FerminCodeDesktopPalette.bevel)
                        .stroke(
                        subagentNameValidationMessage == nil
                            ? Color.clear
                            : FerminCodeDesktopPalette.danger,
                        lineWidth: 1
                    )
                )
                .disabled(isCreating)
                .focused($focusedField, equals: .name)
                .accessibilityHint(
                    subagentNameValidationMessage ?? "Podés dejarlo vacío."
                )
                .accessibilityIdentifier("fermin.desktop.subagent.name")
            if let subagentNameValidationMessage {
                Text(subagentNameValidationMessage)
                    .font(.system(size: 10))
                    .foregroundColor(FerminCodeDesktopPalette.danger)
                    .accessibilityIdentifier("fermin.desktop.subagent.name.error")
            }
            HStack {
                FerminCodeDesktopSectionLabel(text: "Tarea requerida")
                Spacer()
                if let subagentTaskUsageLabel {
                    Text(subagentTaskUsageLabel)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(
                            subagentTaskValidationMessage == nil
                                ? FerminCodeDesktopPalette.warning
                                : FerminCodeDesktopPalette.danger
                        )
                        .accessibilityLabel("Tamaño de la tarea: \(subagentTaskUsageLabel)")
                }
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $store.subagentTaskDraft)
                    .font(.system(size: 13))
                    .foregroundColor(FerminCodeDesktopPalette.primary)
                    .ferminSheetEditorScrollBackground()
                    .ferminDesktopTextEditorAppearance()
                    .background(Color.clear)
                    .frame(minHeight: 150)
                    .padding(6)
                    .disabled(isCreating)
                    .focused($focusedField, equals: .task)
                    .onExitCommand { focusedField = nil }
                    .accessibilityLabel("Tarea del subagente")
                    .accessibilityHint(
                        subagentTaskValidationMessage
                            ?? "Retorno agrega una línea. Comando Retorno crea el subagente. Escape sale del editor."
                    )
                    .accessibilityIdentifier("fermin.desktop.subagent.task")
                if store.subagentTaskDraft.isEmpty {
                    Text("Describí el resultado esperado y cualquier restricción…")
                        .font(.system(size: 13))
                        .foregroundColor(FerminCodeDesktopPalette.muted)
                        .padding(.leading, 12)
                        .padding(.top, 14)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .ferminCodeInsetSurface()
            .overlay(
                RoundedRectangle(cornerRadius: FerminCodeDesktopPalette.bevel)
                    .stroke(
                    subagentTaskValidationMessage != nil
                        ? FerminCodeDesktopPalette.danger
                        : (focusedField == .task
                        ? FerminCodeDesktopPalette.accent.opacity(0.78)
                        : FerminCodeDesktopPalette.separator),
                    lineWidth: subagentTaskValidationMessage != nil
                        || focusedField == .task ? 1.5 : 1
                )
            )
            if let subagentTaskValidationMessage {
                Text(subagentTaskValidationMessage)
                    .font(.system(size: 10))
                    .foregroundColor(FerminCodeDesktopPalette.danger)
                    .accessibilityIdentifier("fermin.desktop.subagent.task.error")
            }
            HStack {
                Label("Retorno: nueva línea · ⌘↩: crear", systemImage: "command")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(FerminCodeDesktopPalette.secondary)
                Spacer()
                Button {
                    Task {
                        _ = await store.createSubagent(
                            message: store.subagentTaskDraft,
                            displayName: store.subagentDisplayNameDraft
                        )
                    }
                } label: {
                    HStack(spacing: 7) {
                        if isCreating {
                            ProgressView().controlSize(.small)
                        }
                        Text(isCreating ? "Creando…" : "Crear subagente")
                    }
                }
                .buttonStyle(FerminCodeDesktopButtonStyle(prominent: true))
                .disabled(!canConfirmSubagent)
                .keyboardShortcut(.return, modifiers: [.command])
                .help(subagentConfirmHelp)
                .accessibilityHint(subagentConfirmHelp)
                .accessibilityIdentifier("fermin.desktop.subagent.confirm")
            }
        }
        .padding(22)
        .frame(width: 520, height: subagentSheetHeight)
        .background(FerminCodeDesktopPalette.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fermin.desktop.subagent.sheet")
        .onAppear {
            DispatchQueue.main.async { focusedField = .task }
        }
    }

    private var isCreating: Bool {
        store.isCreatingSubagentForSelectedSession
    }

    private var normalizedSubagentName: String {
        FerminCodeDesktopSessionNamePolicy.normalized(store.subagentDisplayNameDraft)
    }

    private var subagentNameValidationMessage: String? {
        guard !normalizedSubagentName.isEmpty else { return nil }
        return FerminCodeDesktopSessionNamePolicy.validationMessage(
            for: store.subagentDisplayNameDraft
        )
    }

    private var subagentTaskValidationMessage: String? {
        FerminCodeDesktopSubagentFormPolicy.taskValidationMessage(
            store.subagentTaskDraft
        )
    }

    private var subagentTaskUsageLabel: String? {
        FerminCodeDesktopSubagentFormPolicy.taskUsageLabel(store.subagentTaskDraft)
    }

    private var canConfirmSubagent: Bool {
        FerminCodeDesktopSubagentFormPolicy.canConfirm(
            task: store.subagentTaskDraft,
            nameValidationMessage: subagentNameValidationMessage,
            isCreating: isCreating
        )
    }

    private var subagentConfirmHelp: String {
        FerminCodeDesktopSubagentFormPolicy.confirmHelp(
            task: store.subagentTaskDraft,
            nameValidationMessage: subagentNameValidationMessage,
            isCreating: isCreating
        )
    }

    private var subagentSheetHeight: CGFloat {
        470
            + (store.errorMessage == nil ? 0 : 48)
            + (subagentNameValidationMessage == nil ? 0 : 22)
            + (subagentTaskValidationMessage == nil ? 0 : 22)
    }
}

private extension View {
    @ViewBuilder
    func ferminSheetEditorScrollBackground() -> some View {
        if #available(macOS 13.0, *) {
            scrollContentBackground(.hidden)
        } else {
            self
        }
    }
}

struct FerminCodeDesktopRenameView: View {
    @EnvironmentObject private var store: FerminCodeDesktopStore
    let currentName: String
    @Binding var isPresented: Bool
    @State private var name = ""
    @FocusState private var isNameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Renombrar sesión")
                .font(.system(size: 18, weight: .semibold))
            FerminCodeDesktopSheetError()
            HStack {
                FerminCodeDesktopSectionLabel(text: "Nombre")
                Spacer()
                Text("\(normalizedName.count)/\(FerminCodeDesktopSessionNamePolicy.maximumLength)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(
                        normalizedName.count > FerminCodeDesktopSessionNamePolicy.maximumLength
                            ? FerminCodeDesktopPalette.danger
                            : FerminCodeDesktopPalette.muted
                    )
                    .accessibilityLabel(
                        "\(normalizedName.count) de \(FerminCodeDesktopSessionNamePolicy.maximumLength) caracteres"
                    )
            }
            TextField("Nombre", text: $name)
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .frame(height: 36)
                .background(FerminCodeDesktopPalette.composer)
                .overlay(
                    Rectangle().stroke(
                        validationMessage == nil
                            ? FerminCodeDesktopPalette.separator
                            : FerminCodeDesktopPalette.danger,
                        lineWidth: 1
                    )
                )
                .disabled(isRenaming)
                .focused($isNameFocused)
                .accessibilityHint(validationMessage ?? "Escribí un nombre distinto al actual.")
                .accessibilityIdentifier("fermin.desktop.rename.name")
            if let validationMessage {
                Text(validationMessage)
                    .font(.system(size: 10))
                    .foregroundColor(FerminCodeDesktopPalette.danger)
                    .accessibilityIdentifier("fermin.desktop.rename.name.error")
            }
            HStack {
                Spacer()
                Button(isRenaming ? "Ocultar" : "Cancelar") { isPresented = false }
                    .buttonStyle(FerminCodeDesktopButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .help(
                        isRenaming
                            ? "La sesión se seguirá renombrando"
                            : "Cerrar sin cambiar el nombre"
                    )
                Button {
                    Task {
                        if await store.renameSelectedSession(name) { isPresented = false }
                    }
                } label: {
                    HStack(spacing: 7) {
                        if isRenaming {
                            ProgressView().controlSize(.small)
                        }
                        Text(isRenaming ? "Guardando…" : "Guardar")
                    }
                }
                .buttonStyle(FerminCodeDesktopButtonStyle(prominent: true))
                .disabled(!canRename)
                .keyboardShortcut(.defaultAction)
                .help(renameConfirmHelp)
                .accessibilityHint(renameConfirmHelp)
                .accessibilityIdentifier("fermin.desktop.rename.confirm")
            }
        }
        .padding(22)
        .frame(width: 430, height: store.errorMessage == nil ? 235 : 283)
        .background(FerminCodeDesktopPalette.canvas)
        .onAppear {
            name = currentName
            DispatchQueue.main.async { isNameFocused = true }
        }
    }

    private var normalizedName: String {
        FerminCodeDesktopSessionNamePolicy.normalized(name)
    }

    private var canRename: Bool {
        FerminCodeDesktopRenameFormPolicy.canConfirm(
            name: name,
            currentName: currentName,
            isRenaming: isRenaming
        )
    }

    private var validationMessage: String? {
        FerminCodeDesktopRenameFormPolicy.validationMessage(
            name: name,
            currentName: currentName
        )
    }

    private var renameConfirmHelp: String {
        FerminCodeDesktopRenameFormPolicy.confirmHelp(
            name: name,
            currentName: currentName,
            isRenaming: isRenaming
        )
    }

    private var isRenaming: Bool {
        store.isRenamingSelectedSession
    }
}

private struct FerminCodeDesktopSheetError: View {
    @EnvironmentObject private var store: FerminCodeDesktopStore

    @ViewBuilder
    var body: some View {
        if let error = store.errorMessage {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(FerminCodeDesktopPalette.danger)
                    .accessibilityHidden(true)
                Text(error)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(FerminCodeDesktopPalette.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Error: \(error)")
                Spacer(minLength: 6)
                Button {
                    store.dismissMessages()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Cerrar error")
                .accessibilityLabel("Cerrar error")
            }
            .padding(9)
            .background(FerminCodeDesktopPalette.danger.opacity(0.10))
            .overlay(Rectangle().stroke(FerminCodeDesktopPalette.danger.opacity(0.32)))
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.updatesFrequently)
            .accessibilityIdentifier("fermin.desktop.sheet.error")
        }
    }
}

struct FerminCodeDesktopPreviewView: View {
    @EnvironmentObject private var store: FerminCodeDesktopStore
    let preview: FerminCodeDesktopPreview

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(preview.name)
                        .font(.system(size: 16, weight: .semibold))
                    Text(preview.path)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(FerminCodeDesktopPalette.muted)
                        .lineLimit(1)
                }
                Spacer()
                Button("Cerrar") { store.closePreview() }
                    .buttonStyle(FerminCodeDesktopButtonStyle())
            }
            .padding(16)
            Rectangle().fill(FerminCodeDesktopPalette.separator).frame(height: 1)
            Group {
                switch preview.content {
                case .text(let content, _):
                    ScrollView {
                        Text(content)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(FerminCodeDesktopPalette.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(18)
                    }
                case .image(let data, _):
                    if let image = NSImage(data: data) {
                        ScrollView([.horizontal, .vertical]) {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFit()
                                .padding(18)
                        }
                    } else {
                        Text("No se pudo decodificar la imagen.")
                            .foregroundColor(FerminCodeDesktopPalette.danger)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, minHeight: 520)
        .background(FerminCodeDesktopPalette.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fermin.desktop.preview")
    }
}
