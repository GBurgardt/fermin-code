import AppKit
import FerminCore
import SwiftUI

enum FerminCodeDesktopIteration {
    static let label = "b18"
}

struct FerminCodeDesktopRootView: View {
    @EnvironmentObject private var store: FerminCodeDesktopStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(FerminCodeDesktopPalette.separator)
                .frame(height: 0.5)
            HStack(spacing: 0) {
                FerminCodeDesktopSidebar()
                    .frame(width: FerminCodeDesktopMetrics.sidebarWidth)
                Rectangle()
                    .fill(FerminCodeDesktopPalette.separator)
                    .frame(width: 0.5)
                FerminCodeDesktopConversationView()
                    .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
            }
            notificationArea
        }
        .background(FerminCodeDesktopPalette.background)
        .background(FerminCodeDesktopWindowConfigurator())
        .background(FerminCodeDesktopRepositoryScreenshotCapture())
        .tint(FerminCodeDesktopPalette.accent)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fermin.desktop.root")
        .onAppear {
            store.start()
            if let requestedSession = ProcessInfo.processInfo.environment["FERMIN_REPOSITORY_SCREENSHOT_SESSION"],
               !requestedSession.isEmpty {
                Task { @MainActor in
                    for _ in 0..<24 {
                        if let item = store.sourcedSessions.first(where: {
                            $0.session.displayName.localizedCaseInsensitiveContains(requestedSession)
                        }) {
                            store.selectSession(item)
                            return
                        }
                        try? await Task.sleep(nanoseconds: 250_000_000)
                    }
                }
            }
            guard ProcessInfo.processInfo.environment["FERMIN_REPOSITORY_SCREENSHOT_MODE"] == "history" else {
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                store.isHistoryPresented = true
            }
        }
        .sheet(isPresented: $store.isCreatePresented) {
            FerminCodeDesktopCreateSessionView()
                .environmentObject(store)
        }
        .sheet(isPresented: $store.isHistoryPresented) {
            FerminCodeDesktopHistoryView()
                .environmentObject(store)
        }
        .sheet(isPresented: $store.isRecoveryPresented) {
            FerminCodeDesktopRecoveryView()
                .environmentObject(store)
        }
        .sheet(isPresented: $store.isCredentialsPresented) {
            FerminCodeDesktopCredentialsView()
                .environmentObject(store)
        }
        .sheet(isPresented: $store.isSubagentPresented) {
            FerminCodeDesktopSubagentView()
                .environmentObject(store)
        }
        .sheet(item: previewBinding) { preview in
            FerminCodeDesktopPreviewView(preview: preview)
                .environmentObject(store)
        }
        .alert(
            "Eliminar sesión definitivamente",
            isPresented: $store.isDeleteConfirmationPresented
        ) {
            Button("Cancelar", role: .cancel) {}
            Button("Eliminar", role: .destructive) {
                Task { await store.deleteSelectedSessionPermanently() }
            }
            .disabled(store.isDeletingSelectedSession)
            .accessibilityIdentifier("fermin.desktop.delete.confirm")
        } message: {
            Text(
                "\(store.selectedSession?.displayName ?? "Esta sesión") se eliminará del relay y de Codex. Esta acción no se puede deshacer."
            )
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(nsImage: brandIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
                Text("FERMÍN CODE")
                    .font(.system(size: 11.5, weight: .semibold))
                    .tracking(1.2)
                    .foregroundColor(FerminCodeDesktopPalette.primary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("fermin.desktop.brand")
            .padding(.leading, 72)

            Spacer(minLength: 12)

            connectionStatusSummary
            profileSelector
            Text(FerminCodeDesktopIteration.label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(0.7)
                .foregroundColor(FerminCodeDesktopPalette.tertiary)
                .frame(height: 22)
                .padding(.trailing, 10)
                .accessibilityLabel("Versión de iteración " + FerminCodeDesktopIteration.label)
                .accessibilityIdentifier("fermin.desktop.iteration")
        }
        .frame(height: FerminCodeDesktopMetrics.appHeaderHeight)
        .background(FerminCodeDesktopPalette.canvas)
    }

    @ViewBuilder
    private var connectionStatusSummary: some View {
        if !visibleConnectionStatuses.isEmpty {
            HStack(spacing: 4) {
                ForEach(visibleConnectionStatuses) { status in
                    FerminCodeDesktopConnectionBadge(status: status)
                }
            }
            .frame(height: 28)
        }
    }

    private var visibleConnectionStatuses: [FerminCodeDesktopSourceStatus] {
        FerminCodeRelaySource.allCases.compactMap { source in
            let status = store.sourceStatuses[source]
                ?? FerminCodeDesktopSourceStatus(
                    source: source,
                    phase: .loading,
                    sessionCount: 0,
                    detail: nil,
                    lastUpdatedAt: nil
                )
            return status.phase == .online ? nil : status
        }
    }

    private var profileSelector: some View {
        HStack(spacing: 0) {
            ForEach(FerminCodeRelayProfile.allCases, id: \.self) { profile in
                Button {
                    DispatchQueue.main.async {
                        store.selectProfile(profile)
                    }
                } label: {
                    HStack(spacing: 5) {
                        if store.profile == profile {
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .bold))
                        }
                        Text(profile.displayName)
                    }
                        .font(.system(size: 10.5, weight: store.profile == profile ? .semibold : .medium))
                        .foregroundColor(
                            store.profile == profile
                                ? FerminCodeDesktopPalette.primary
                                : FerminCodeDesktopPalette.secondary
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(
                            store.profile == profile
                                ? FerminCodeDesktopPalette.pressed
                                : Color.clear
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("fermin.desktop.profile.\(profileIdentifier(profile))")
                .accessibilityLabel(profile.displayName)
                .accessibilityAddTraits(store.profile == profile ? .isSelected : [])
            }
        }
        .padding(2)
        .frame(width: 180, height: 29)
        .ferminCodeInsetSurface()
        .disabled(!store.canChangeProfile)
        .accessibilityLabel("Origen de sesiones")
        .accessibilityValue(profileSelectorAccessibilityValue)
        .accessibilityIdentifier("fermin.desktop.profile.selector")
        .help(profileSelectorHelp)
        .padding(.trailing, 2)
    }

    @ViewBuilder
    private var notificationArea: some View {
        if let error = store.errorMessage,
           store.composerSendErrorMessage == nil {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(FerminCodeDesktopPalette.danger)
                Text(error)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(FerminCodeDesktopPalette.primary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                    .textSelection(.enabled)
                    .help(error)
                Spacer()
                Button {
                    store.dismissMessages()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .help("Cerrar error")
                    .accessibilityLabel("Cerrar error")
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Error: \(error)")
            .accessibilityAddTraits(.updatesFrequently)
            .padding(.horizontal, 10)
            .frame(minHeight: 30)
            .background(FerminCodeDesktopPalette.danger.opacity(0.10))
            .overlay(alignment: .top) {
                Rectangle().fill(FerminCodeDesktopPalette.danger.opacity(0.42)).frame(height: 0.5)
            }
            .accessibilityIdentifier("fermin.desktop.error")
        } else if let notice = store.notice {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(FerminCodeDesktopPalette.positive)
                Text(notice)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(FerminCodeDesktopPalette.primary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                    .textSelection(.enabled)
                    .help(notice)
                Spacer()
                Button {
                    store.dismissMessages()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .help("Cerrar aviso")
                    .accessibilityLabel("Cerrar aviso")
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Aviso: \(notice)")
            .accessibilityAddTraits(.updatesFrequently)
            .padding(.horizontal, 10)
            .frame(minHeight: 30)
            .background(FerminCodeDesktopPalette.positive.opacity(0.10))
            .overlay(alignment: .top) {
                Rectangle().fill(FerminCodeDesktopPalette.positive.opacity(0.34)).frame(height: 0.5)
            }
            .accessibilityIdentifier("fermin.desktop.notice")
        }
    }

    private var profileSelectorHelp: String {
        if store.isSending { return "Esperá a que termine el envío para cambiar de equipo" }
        if store.isAddingAttachments {
            return "Esperá a que terminen de prepararse las imágenes para cambiar de equipo"
        }
        if store.isCreatingSession {
            return "Esperá a que la nueva sesión esté lista para cambiar de equipo"
        }
        return "Filtrar sesiones por equipo"
    }

    private var profileSelectorAccessibilityValue: String {
        let status = store.canChangeProfile ? "Disponible" : "Temporalmente bloqueado"
        return "\(store.profile.displayName), \(status)"
    }

    private var brandIcon: NSImage {
        if let url = Bundle.main.url(forResource: "Fermin", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            return icon
        }
        return NSApplication.shared.applicationIconImage
    }

    private var previewBinding: Binding<FerminCodeDesktopPreview?> {
        Binding(
            get: { store.preview },
            set: { if $0 == nil { store.closePreview() } }
        )
    }

    private func profileIdentifier(_ profile: FerminCodeRelayProfile) -> String {
        profile == .todo ? "todo" : profile.rawValue
    }
}

struct FerminCodeDesktopConnectionBadge: View {
    let status: FerminCodeDesktopSourceStatus

    private static let stableWidth: CGFloat = 150
    private static let phaseWidth: CGFloat = 68

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: status.phase.symbolName)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 12, height: 12)
                .accessibilityHidden(true)
            Text(status.source.displayName)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .frame(width: 50, alignment: .leading)
            Text(status.phase.label)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(color)
                .lineLimit(1)
                .frame(width: Self.phaseWidth, alignment: .leading)
        }
        .foregroundColor(FerminCodeDesktopPalette.secondary)
        .padding(.horizontal, 6)
        .frame(width: Self.stableWidth, height: 24, alignment: .leading)
        .ferminCodeRaisedSurface(
            fill: status.phase == .online
                ? Color.clear
                : color.opacity(0.10),
            topLight: status.phase == .online
                ? Color.clear
                : FerminCodeDesktopPalette.topLight
        )
        .help("\(status.source.displayName): \(status.phase.label). \(status.detail ?? "")")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(status.source.displayName), \(status.phase.label), \(status.sessionCount) sesiones")
        .accessibilityValue(phaseValue)
        .accessibilityIdentifier("fermin.desktop.connection.\(status.source.rawValue)")
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private var color: Color {
        switch status.phase {
        case .online: return FerminCodeDesktopPalette.positive
        case .loading, .stale, .missingCredential: return FerminCodeDesktopPalette.warning
        case .offline: return FerminCodeDesktopPalette.danger
        }
    }

    private var phaseValue: String {
        switch status.phase {
        case .missingCredential: return "missing-credential"
        case .loading: return "loading"
        case .online: return "online"
        case .stale: return "stale"
        case .offline: return "offline"
        }
    }
}
