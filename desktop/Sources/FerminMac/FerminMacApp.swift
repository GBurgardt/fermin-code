import AppKit
import SwiftUI

@main
@MainActor
struct FerminMacApp: App {
    @StateObject private var store: FerminCodeDesktopStore
    @Environment(\.scenePhase) private var scenePhase

    init() {
        _store = StateObject(
            wrappedValue: FerminCodeDesktopStore(
                relay: FerminCodeDesktopRelayService()
            )
        )
    }

    var body: some Scene {
        WindowGroup("Fermín Code") {
            FerminCodeDesktopRootView()
                .environmentObject(store)
                .frame(minWidth: 920, minHeight: 620)
                .onChange(of: scenePhase) { phase in
                    store.setAppActive(phase == .active)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Nueva sesión") {
                    guard store.canInvokeCreateShortcut else { return }
                    store.isCreatePresented = true
                    Task { await store.loadProjects() }
                }
                .keyboardShortcut("n", modifiers: [.command])
                .disabled(!store.canInvokeCreateShortcut)
                Divider()
                Button("Cerrar ventana") { NSApp.keyWindow?.performClose(nil) }
                    .keyboardShortcut("w", modifiers: [.command])
            }

            CommandMenu("Fermín Code") {
                Button("Enviar mensaje") {
                    Task { await store.sendComposer() }
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!store.canInvokeComposerShortcut)

                Button("Interrumpir") {
                    Task { await store.interruptSelectedSession() }
                }
                .keyboardShortcut(".", modifiers: [.command])
                .disabled(!store.canInvokeInterruptShortcut)

                Divider()

                Button("Buscar sesiones") {
                    store.requestSessionSearchFocus()
                }
                .keyboardShortcut("f", modifiers: [.command])
                .disabled(store.hasPresentedModal)

                Button("Actualizar") {
                    Task { await store.refreshAll() }
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(store.hasPresentedModal || store.isRefreshing)

                Button("Historial") {
                    store.isHistoryPresented = true
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(store.hasPresentedModal)

                Button("Recuperar sesión…") {
                    store.isRecoveryPresented = true
                }
                .disabled(store.hasPresentedModal)
            }
        }

        Settings {
            FerminCodeDesktopCredentialsView()
                .environmentObject(store)
        }
    }
}
