import FerminCore
import SwiftUI

struct FerminCodeDesktopSidebar: View {
    @EnvironmentObject private var store: FerminCodeDesktopStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isSearchFocused: Bool
    @State private var isUnpinnedExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            actions
            search
            sessionList
        }
        .background(FerminCodeDesktopPalette.sidebar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fermin.desktop.session.sidebar")
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button {
                store.isCreatePresented = true
                Task { await store.loadProjects() }
            } label: {
                HStack(spacing: 6) {
                    if store.isCreatingSession {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "plus")
                    }
                    Text(newSessionActionTitle)
                }
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(FerminCodeDesktopButtonStyle(prominent: true))
            .disabled(!store.canCreateSession)
            .help(newSessionActionHelp)
            .accessibilityLabel(newSessionActionTitle)
            .accessibilityValue(newSessionActionAccessibilityValue)
            .accessibilityHint(newSessionActionHelp)
            .accessibilityIdentifier("fermin.desktop.session.new")

            Menu {
                Button {
                    Task { await store.refreshAll() }
                } label: {
                    Label("Actualizar", systemImage: "arrow.clockwise")
                }
                .disabled(store.isRefreshing)
                .accessibilityIdentifier("fermin.desktop.session.refresh")

                Button {
                    store.isHistoryPresented = true
                } label: {
                    Label("Historial", systemImage: "clock.arrow.circlepath")
                }
                .accessibilityIdentifier("fermin.desktop.history.open")

                Section("Conexiones") {
                    ForEach(FerminCodeRelaySource.allCases) { source in
                        let status = store.sourceStatuses[source]
                        Button(action: {}) {
                            Label(
                                "\(source.displayName): \(status?.phase.label ?? "Conectando")",
                                systemImage: status?.phase.symbolName ?? "arrow.triangle.2.circlepath"
                            )
                        }
                        .disabled(true)
                    }
                }

                Toggle("Incluir minimizadas", isOn: $store.includeMinimized)
                    .accessibilityIdentifier("fermin.desktop.session.includeMinimized")

                Divider()

                Button {
                    store.isCredentialsPresented = true
                } label: {
                    Label("Ajustes", systemImage: "gearshape.fill")
                }
                .accessibilityIdentifier("fermin.desktop.credentials.open")
            } label: {
                Group {
                    if store.isRefreshing {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
                .foregroundColor(FerminCodeDesktopPalette.primary)
                .frame(
                    width: FerminCodeDesktopMetrics.iconControlSize,
                    height: FerminCodeDesktopMetrics.iconControlSize
                )
                .ferminCodeRaisedSurface(fill: FerminCodeDesktopPalette.raised)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(
                width: FerminCodeDesktopMetrics.iconControlSize,
                height: FerminCodeDesktopMetrics.iconControlSize
            )
            .help(store.isRefreshing ? "Actualizando sesiones" : "Más acciones")
            .accessibilityLabel("Más acciones")
            .accessibilityValue(store.isRefreshing ? "Actualizando" : "Disponible")
            .accessibilityIdentifier("fermin.desktop.session.actions")
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var newSessionActionHelp: String {
        FerminCodeDesktopNewSessionActionPresentation.help(
            profile: store.profile,
            credentialPresence: store.credentialPresence,
            isBootstrapping: store.isBootstrapping,
            creationPhase: store.creationPhase
        )
    }

    private var newSessionActionTitle: String {
        FerminCodeDesktopNewSessionActionPresentation.title(
            creationPhase: store.creationPhase
        )
    }

    private var newSessionActionAccessibilityValue: String {
        FerminCodeDesktopNewSessionActionPresentation.accessibilityValue(
            creationPhase: store.creationPhase
        )
    }

    private var search: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(FerminCodeDesktopPalette.muted)
            TextField("Buscar sesiones", text: $store.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($isSearchFocused)
                .onExitCommand {
                    if store.searchText.isEmpty {
                        isSearchFocused = false
                    } else {
                        store.searchText = ""
                    }
                }
                .accessibilityIdentifier("fermin.desktop.session.search")
            if !store.searchText.isEmpty {
                Button {
                    store.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(FerminCodeDesktopPalette.muted)
                .help("Borrar búsqueda")
                .accessibilityLabel("Borrar búsqueda")
                .accessibilityIdentifier("fermin.desktop.session.search.clear")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 34)
        .ferminCodeInsetSurface()
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .onChange(of: store.sessionSearchFocusRequest) { _ in
            isSearchFocused = true
        }
    }

    @ViewBuilder
    private var sessionList: some View {
        if store.visibleSessions.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                if store.isBootstrapping {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Preparando Fermín Code")
                } else {
                    Image(systemName: emptySymbol)
                        .font(.system(size: 18, weight: .light))
                        .foregroundColor(FerminCodeDesktopPalette.muted)
                }
                Text(emptyTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(FerminCodeDesktopPalette.secondary)
                Text(emptyDetail)
                    .font(.system(size: 11))
                    .foregroundColor(FerminCodeDesktopPalette.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 210)
                emptyAction
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(16)
            .accessibilityAddTraits(.updatesFrequently)
            .accessibilityIdentifier(emptyIdentifier)
        } else {
            ScrollView {
                LazyVStack(spacing: FerminCodeDesktopMetrics.sidebarRowGap) {
                    ForEach(store.pinnedSessions) { item in
                        sessionListItem(item, pinned: true)
                    }

                    if !store.unpinnedSessions.isEmpty {
                        unpinnedDisclosure
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
    }

    private func sessionListItem(
        _ item: FerminCodeRelaySourcedSession,
        pinned: Bool
    ) -> some View {
        ZStack(alignment: .topTrailing) {
            Button {
                store.selectSession(item)
            } label: {
                FerminCodeDesktopSessionRow(
                    item: item,
                    selected: store.selectedRoute?.id == item.id,
                    showsSource: store.profile == .todo,
                    activityStatusOverride: store.effectiveActivityStatus(for: item)
                )
                .padding(.trailing, 24)
            }
            .buttonStyle(.plain)
            .disabled(store.isSending || store.isAddingAttachments)
            .help(
                store.isSending || store.isAddingAttachments
                    ? "Esperá a que termine la operación del compositor"
                    : "Abrir \(item.session.displayName)"
            )
            .accessibilityIdentifier(
                "fermin.desktop.session.row.\(item.source.rawValue).\(item.session.windowID)"
            )

            Button {
                withAnimation(disclosureAnimation) {
                    store.setSessionPinned(item, pinned: !pinned)
                }
            } label: {
                Image(systemName: pinned ? "pin.slash" : "pin.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(pinned ? FerminCodeDesktopPalette.muted : FerminCodeDesktopPalette.accent)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(pinned ? 0.62 : 0.82)
            .padding(.top, 3)
            .padding(.trailing, 2)
            .help(pinned ? "Desfijar sesión" : "Fijar sesión")
            .accessibilityLabel(pinned ? "Desfijar \(item.session.displayName)" : "Fijar \(item.session.displayName)")
            .accessibilityIdentifier(
                "fermin.desktop.session.\(pinned ? "unpin" : "pin").\(item.source.rawValue).\(item.session.windowID)"
            )
        }
        .contextMenu {
            Button {
                withAnimation(disclosureAnimation) {
                    store.setSessionPinned(item, pinned: !pinned)
                }
            } label: {
                Label(pinned ? "Desfijar" : "Fijar", systemImage: pinned ? "pin.slash" : "pin.fill")
            }

            Button(role: .destructive) {
                store.selectSession(item)
                if store.selectedRoute?.id == item.id {
                    store.isDeleteConfirmationPresented = true
                }
            } label: {
                Label("Eliminar definitivamente…", systemImage: "trash")
            }
            .disabled(store.isSending || store.isAddingAttachments)
        }
    }

    private var unpinnedDisclosure: some View {
        VStack(spacing: 3) {
            Rectangle()
                .fill(FerminCodeDesktopPalette.separator)
                .frame(height: 0.5)
                .padding(.vertical, 2)

            Button {
                withAnimation(disclosureAnimation) {
                    isUnpinnedExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(showsUnpinnedSessions ? 90 : 0))
                        .accessibilityHidden(true)
                    Text("Sin fijar")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer(minLength: 8)
                    Text("\(store.unpinnedSessions.count)")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(FerminCodeDesktopPalette.muted)
                }
                .foregroundColor(FerminCodeDesktopPalette.secondary)
                .padding(.horizontal, 8)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Sesiones sin fijar")
            .accessibilityValue(showsUnpinnedSessions ? "Expandida, \(store.unpinnedSessions.count) sesiones" : "Contraída, \(store.unpinnedSessions.count) sesiones")
            .accessibilityHint(showsUnpinnedSessions ? "Oculta las sesiones sin fijar" : "Muestra las sesiones sin fijar")
            .accessibilityIdentifier("fermin.desktop.session.unpinned.disclosure")

            if showsUnpinnedSessions {
                ForEach(store.unpinnedSessions) { item in
                    sessionListItem(item, pinned: false)
                }
                .transition(.opacity)
            }
        }
    }

    private var showsUnpinnedSessions: Bool {
        isUnpinnedExpanded
            || !store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var disclosureAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.14)
    }

    private var emptySymbol: String {
        if hasHiddenMinimizedMatches { return "arrow.down.right.and.arrow.up.left" }
        if !store.searchText.isEmpty { return "magnifyingglass" }
        if isPartiallyConfigured { return "key" }
        return hasConfiguredSource ? "rectangle.stack" : "key"
    }

    private var emptyTitle: String {
        if store.isBootstrapping { return "Preparando Fermín Code" }
        if hasHiddenMinimizedMatches {
            return store.searchText.isEmpty
                ? "Sesiones minimizadas ocultas"
                : "Coincidencias minimizadas"
        }
        if !store.searchText.isEmpty { return "Sin coincidencias" }
        if isPartiallyConfigured { return "Falta conectar \(missingSourceNames)" }
        return hasConfiguredSource ? "Sin sesiones" : "Falta configurar el token"
    }

    private var emptyDetail: String {
        if store.isBootstrapping {
            return "Leyendo las credenciales seguras y conectando los relays."
        }
        if hasHiddenMinimizedMatches {
            let count = hiddenMinimizedMatches.count
            return count == 1
                ? "Mostrá las minimizadas para ver esta sesión."
                : "Mostrá las minimizadas para ver estas \(count) sesiones."
        }
        if !store.searchText.isEmpty { return "Probá con otro nombre o proyecto." }
        if isPartiallyConfigured {
            return "Abrí Ajustes y guardá el token de \(missingSourceNames) para completar Todo."
        }
        if hasConfiguredSource, store.profile == .todo {
            return "Elegí Personal o Puky arriba para crear una sesión."
        }
        return hasConfiguredSource
            ? "Sólo aparecen sesiones creadas o reanudadas en Fermín Code."
            : "Abrí Ajustes y guardá el token de cada Mac en Keychain."
    }

    @ViewBuilder
    private var emptyAction: some View {
        if store.isBootstrapping {
            EmptyView()
        } else if hasHiddenMinimizedMatches {
            Button("Mostrar minimizadas") { store.includeMinimized = true }
                .buttonStyle(FerminCodeDesktopButtonStyle(prominent: true))
                .accessibilityIdentifier("fermin.desktop.session.empty.showMinimized")
        } else if !store.searchText.isEmpty {
            Button("Borrar búsqueda") { store.searchText = "" }
                .buttonStyle(FerminCodeDesktopButtonStyle())
                .accessibilityIdentifier("fermin.desktop.session.empty.clearSearch")
        } else if !missingCredentialSources.isEmpty {
            Button("Configurar tokens") { store.isCredentialsPresented = true }
                .buttonStyle(FerminCodeDesktopButtonStyle(prominent: true))
                .accessibilityIdentifier("fermin.desktop.session.empty.openCredentials")
        } else if store.canCreateSession {
            Button("Crear sesión") {
                store.isCreatePresented = true
                Task { await store.loadProjects() }
            }
            .buttonStyle(FerminCodeDesktopButtonStyle(prominent: true))
            .accessibilityIdentifier("fermin.desktop.session.empty.create")
        }
    }

    private var hasConfiguredSource: Bool {
        FerminCodeDesktopCredentialCoveragePolicy.hasConfiguredSource(
            profile: store.profile,
            presence: store.credentialPresence
        )
    }

    private var missingCredentialSources: [FerminCodeRelaySource] {
        FerminCodeDesktopCredentialCoveragePolicy.missingSources(
            profile: store.profile,
            presence: store.credentialPresence
        )
    }

    private var isPartiallyConfigured: Bool {
        hasConfiguredSource && !missingCredentialSources.isEmpty
    }

    private var missingSourceNames: String {
        missingCredentialSources.map(\.displayName).joined(separator: " y ")
    }

    private var hiddenMinimizedMatches: [FerminCodeRelaySourcedSession] {
        guard !store.includeMinimized else { return [] }
        return FerminCodeDesktopSessionListPolicy.hiddenMinimizedMatches(
            store.sourcedSessions,
            profile: store.profile,
            searchText: store.searchText
        )
    }

    private var hasHiddenMinimizedMatches: Bool {
        !hiddenMinimizedMatches.isEmpty
    }

    private var emptyIdentifier: String {
        if store.isBootstrapping {
            return "fermin.desktop.session.empty.bootstrapping"
        }
        if hasHiddenMinimizedMatches {
            return "fermin.desktop.session.empty.minimized"
        }
        if !store.searchText.isEmpty {
            return "fermin.desktop.session.empty.search"
        }
        if isPartiallyConfigured {
            return "fermin.desktop.session.empty.credentials.partial"
        }
        return hasConfiguredSource
            ? "fermin.desktop.session.empty"
            : "fermin.desktop.session.empty.credentials"
    }
}

struct FerminCodeDesktopSessionRow: View {
    let item: FerminCodeRelaySourcedSession
    let selected: Bool
    let showsSource: Bool
    var activityStatusOverride: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: FerminCodeDesktopActivityPresentation.symbol(
                    for: activityStatus
                ))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(activityColor)
                    .frame(width: 11, height: 11)
                    .accessibilityHidden(true)
                Text(sessionDisplayName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(FerminCodeDesktopPalette.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(sessionDisplayName)
                Spacer(minLength: 6)
                if showsSource {
                    Text(item.source.displayName.uppercased())
                        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                        .tracking(0.65)
                        .foregroundColor(FerminCodeDesktopPalette.tertiary)
                        .fixedSize()
                }
            }

            HStack(spacing: 6) {
                Text(item.session.lastMessagePreview ?? statusLabel)
                    .font(.system(size: 10.5))
                    .foregroundColor(FerminCodeDesktopPalette.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(item.session.lastMessagePreview ?? statusLabel)
                Spacer(minLength: 4)
                if let timestamp = FerminCodeDesktopTimestamp.label(item.session.updatedAt) {
                    Text(timestamp)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(FerminCodeDesktopPalette.muted)
                        .fixedSize()
                }
            }

            Text(item.session.projectName ?? item.session.projectPath ?? "Sin proyecto")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(FerminCodeDesktopPalette.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(item.session.projectName ?? item.session.projectPath ?? "Sin proyecto")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ferminCodeRaisedSurface(
            fill: selected
                ? FerminCodeDesktopPalette.selected
                : Color.clear,
            topLight: selected
                ? FerminCodeDesktopPalette.topLight
                : Color.clear
        )
        .overlay(alignment: .leading) {
            if selected {
                Rectangle()
                    .fill(FerminCodeDesktopPalette.accent)
                    .frame(width: 2)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(item.session.displayName), \(item.source.displayName), \(statusLabel)"
        )
        .accessibilityValue(selected ? "Seleccionada" : "No seleccionada")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var statusLabel: String {
        FerminCodeDesktopActivityPresentation.label(for: activityStatus)
    }

    private var activityStatus: String {
        activityStatusOverride ?? item.session.activityStatus
    }

    private var sessionDisplayName: String {
        item.session.displayName.isEmpty ? "Sesión sin nombre" : item.session.displayName
    }

    private var activityColor: Color {
        switch FerminCodeDesktopActivityPresentation.state(for: activityStatus) {
        case .ready: return FerminCodeDesktopPalette.positive
        case .busy: return FerminCodeDesktopPalette.warning
        case .failed: return FerminCodeDesktopPalette.danger
        case .inactive, .unknown: return FerminCodeDesktopPalette.muted
        }
    }
}
