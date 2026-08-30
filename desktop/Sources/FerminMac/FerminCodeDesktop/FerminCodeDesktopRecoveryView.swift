import FerminCore
import SwiftUI

struct FerminCodeDesktopRecoveryView: View {
    @EnvironmentObject private var store: FerminCodeDesktopStore
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recuperar sesión")
                        .font(.system(size: 20, weight: .semibold))
                    Text("Sesiones locales que todavía no pertenecen a Fermín Code")
                        .font(.system(size: 11))
                        .foregroundColor(FerminCodeDesktopPalette.muted)
                }
                Spacer()
                Button("Cerrar") { store.isRecoveryPresented = false }
                    .buttonStyle(.plain)
                    .foregroundColor(FerminCodeDesktopPalette.secondary)
                    .accessibilityIdentifier("fermin.desktop.recovery.close")
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(FerminCodeDesktopPalette.muted)
                TextField("Buscar por nombre, proyecto o contenido", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .accessibilityIdentifier("fermin.desktop.recovery.search")
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(FerminCodeDesktopPalette.muted)
                    .accessibilityLabel("Borrar búsqueda")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .ferminCodeInsetSurface()
            .padding(.horizontal, 22)
            .padding(.bottom, 14)

            if let message = store.recoveryLoadState.partialMessage {
                recoveryStatus(message)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 12)
            }

            Rectangle().fill(FerminCodeDesktopPalette.separator).frame(height: 1)

            if store.isLoadingRecovery, store.recoveryItems.isEmpty {
                Spacer()
                ProgressView("Buscando sesiones…")
                Spacer()
            } else if let message = store.recoveryLoadState.failureMessage,
                      store.recoveryItems.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Text(message)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(FerminCodeDesktopPalette.secondary)
                    Button("Reintentar") {
                        Task { await store.loadRecoverableSessions(text: query) }
                    }
                    .buttonStyle(FerminCodeDesktopButtonStyle())
                    .disabled(store.isLoadingRecovery)
                    .accessibilityIdentifier("fermin.desktop.recovery.retry")
                }
                Spacer()
            } else if store.recoveryItems.isEmpty {
                Spacer()
                VStack(spacing: 6) {
                    Text(query.isEmpty ? "No hay sesiones pendientes" : "No hay coincidencias")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(FerminCodeDesktopPalette.secondary)
                    Text(query.isEmpty ? "Todo lo detectado ya está en Fermín Code." : "Probá con otra palabra del trabajo o del proyecto.")
                        .font(.system(size: 11))
                        .foregroundColor(FerminCodeDesktopPalette.muted)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(store.recoveryItems) { sourcedItem in
                            recoveryRow(sourcedItem)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(width: 780, height: 620)
        .background(FerminCodeDesktopPalette.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fermin.desktop.recovery.sheet")
        .task(id: query) {
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await store.loadRecoverableSessions(text: query)
        }
        .onDisappear {
            store.invalidateRecoveryRequestForLifecycle()
        }
        .onExitCommand {
            if !query.isEmpty {
                query = ""
            } else if searchFocused {
                searchFocused = false
            } else {
                store.isRecoveryPresented = false
            }
        }
    }

    private func recoveryRow(_ sourcedItem: FerminCodeDesktopSourcedRecoveryItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(sourcedItem.item.sessionName.isEmpty ? "Sesión sin nombre" : sourcedItem.item.sessionName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(FerminCodeDesktopPalette.primary)
                        .lineLimit(1)
                    Text(sourcedItem.source.displayName.uppercased())
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(FerminCodeDesktopPalette.accent)
                    if sourcedItem.item.archived {
                        Text("ARCHIVADA")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(FerminCodeDesktopPalette.muted)
                    }
                }
                if !sourcedItem.item.preview.isEmpty {
                    Text(sourcedItem.item.preview)
                        .font(.system(size: 12.5))
                        .foregroundColor(FerminCodeDesktopPalette.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 7) {
                    Text(sourcedItem.item.projectName)
                    if let timestamp = FerminCodeDesktopTimestamp.label(sourcedItem.item.updatedAt) {
                        Text("·")
                        Text(timestamp)
                    }
                    if let matchedIn = sourcedItem.item.matchedIn {
                        Text("· \(matchedIn)")
                    }
                }
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(FerminCodeDesktopPalette.muted)
            }
            Spacer()
            Button {
                Task { _ = await store.recoverSession(sourcedItem) }
            } label: {
                HStack(spacing: 6) {
                    if store.activeMutations.contains("recover:\(sourcedItem.id)") {
                        ProgressView().controlSize(.small)
                    }
                    Text(
                        store.activeMutations.contains("recover:\(sourcedItem.id)")
                            ? "Recuperando…"
                            : "Recuperar"
                    )
                }
            }
            .buttonStyle(FerminCodeDesktopButtonStyle(prominent: true))
            .disabled(
                !sourcedItem.item.canRecover
                    || store.activeMutations.contains(where: { $0.hasPrefix("recover:") })
            )
            .accessibilityIdentifier("fermin.desktop.recovery.recover")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .ferminCodeRaisedSurface(fill: FerminCodeDesktopPalette.surface)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fermin.desktop.recovery.row.\(sourcedItem.source.rawValue)")
    }

    private func recoveryStatus(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(FerminCodeDesktopPalette.warning)
            Text(message)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(FerminCodeDesktopPalette.secondary)
            Spacer()
            Button("Reintentar") {
                Task { await store.loadRecoverableSessions(text: query) }
            }
            .buttonStyle(.plain)
            .foregroundColor(FerminCodeDesktopPalette.accent)
        }
    }
}
