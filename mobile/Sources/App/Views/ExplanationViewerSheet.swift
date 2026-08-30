import SwiftUI

struct ExplanationViewerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: ExplanationViewerViewModel

    private var palette: KycodeDocumentReaderPalette {
        viewModel.theme.palette
    }

    private var document: KycodeReaderDocument? {
        viewModel.presentedDocument
    }

    var body: some View {
        VStack(spacing: 0) {
            readerHeader

            Group {
                if let document {
                    explanationContent(document)
                } else {
                    ContentUnavailableView(
                        "Documento no disponible",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("El contenido todavía no está listo.")
                    )
                    .foregroundStyle(palette.ink)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(palette.background)
        }
        .accessibilityIdentifier("explanation-viewer-sheet")
        .animation(.easeInOut(duration: 0.20), value: viewModel.theme)
        .onDisappear {
            viewModel.dismiss()
        }
    }

    private var readerHeader: some View {
        HStack(spacing: 16) {
            Image(systemName: document?.kind.iconName ?? "doc.text")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color(red: 0.68, green: 0.76, blue: 0.90))
                .frame(width: 44, height: 44)
                .overlay {
                    Rectangle()
                        .stroke(Color.white.opacity(0.34), lineWidth: 1)
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("EXPLANATION PREVIEW")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.7)
                    .foregroundStyle(Color.white.opacity(0.62))

                Text(document.map { displayTitle(for: $0) } ?? "Lectura")
                    .font(.system(size: 20, weight: .semibold, design: .serif))
                    .tracking(-0.2)
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(document?.kind == .improvedPrompt ? "KYCODE · PROMPT" : "KYCODE · EXPLAINER")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(Color.white.opacity(0.60))
            }

            Spacer(minLength: 12)

            Button {
                guard let document else { return }
                UIPasteboard.general.string = document.content
                AppHaptics.shared.play(.conversationSelection)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .foregroundStyle(.white.opacity(document == nil ? 0.42 : 0.94))
            .overlay {
                Rectangle()
                    .stroke(Color.white.opacity(0.34), lineWidth: 1)
            }
            .disabled(document == nil)
            .accessibilityLabel(document?.kind.copyAccessibilityLabel ?? "Copiar documento")
            .accessibilityIdentifier("explanation-viewer-copy")

            Button {
                AppHaptics.shared.play(.conversationSelection)
                withAnimation(.easeInOut(duration: 0.20)) {
                    viewModel.toggleTheme()
                }
            } label: {
                Image(systemName: viewModel.theme.toggleIconName)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .foregroundStyle(.white.opacity(0.94))
            .overlay {
                Rectangle()
                    .stroke(Color.white.opacity(0.34), lineWidth: 1)
            }
            .accessibilityLabel(viewModel.theme.toggleAccessibilityLabel)
            .accessibilityValue(viewModel.theme.accessibilityName)
            .accessibilityIdentifier("explanation-viewer-theme-toggle")

            Button {
                viewModel.dismiss()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 44, height: 44)
            }
            .foregroundStyle(.white.opacity(0.94))
            .overlay {
                Rectangle()
                    .stroke(Color.white.opacity(0.34), lineWidth: 1)
            }
            .accessibilityLabel("Cerrar lector")
            .accessibilityIdentifier("explanation-viewer-close")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(Color(red: 0.075, green: 0.094, blue: 0.125))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(palette.accent)
                .frame(height: 2)
        }
    }

    private func explanationContent(_ document: KycodeReaderDocument) -> some View {
        GeometryReader { geometry in
            let isTablet = UIDevice.current.userInterfaceIdiom == .pad
            let isPortrait = geometry.size.height >= geometry.size.width
            let columnWidth: CGFloat = isTablet ? (isPortrait ? 620 : 680) : geometry.size.width
            let horizontalInset: CGFloat = isTablet ? (isPortrait ? 56 : 80) : 24
            let topInset: CGFloat = isTablet ? (isPortrait ? 56 : 40) : 32

            ScrollView {
                MarkdownBubbleText(
                    markdown: document.content,
                    isUser: false,
                    presentation: .fileViewer,
                    readerPalette: palette
                )
                .frame(maxWidth: columnWidth, alignment: .leading)
                .padding(.horizontal, horizontalInset)
                .padding(.top, topInset)
                .padding(.bottom, 96)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .background(palette.background)
        }
        .accessibilityIdentifier("explanation-viewer-content")
    }

    private func displayTitle(for document: KycodeReaderDocument) -> String {
        for line in document.content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("# ") else { continue }
            let title = trimmed.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                return String(title)
            }
        }
        return document.title
    }
}

struct ExplanationLauncher: View {
    let document: KycodeReaderDocument

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: document.kind.iconName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppTheme.accent)
                .frame(width: 36, height: 36)
                .background(AppTheme.accent.opacity(0.12))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(document.kind.launcherTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.ink)
                Text(document.kind.launcherSubtitle)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(AppTheme.inkMuted)
            }

            Spacer(minLength: 8)

            Image(systemName: "arrow.up.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppTheme.inkMuted)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: 360, alignment: .leading)
        .background(AppTheme.cardSurface.opacity(0.78))
        .contentShape(Rectangle())
    }
}

#if DEBUG
struct ExplanationViewerUITestHarness: View {
    @StateObject private var viewModel = ExplanationViewerViewModel()

    private let document = KycodeReaderDocument(
        id: "explainer-ui-test",
        messageId: "explainer-ui-test",
        kind: .explanation,
        content: """
        # Claridad progresiva

        Esta explicación vive **fuera del chat** y se abre únicamente cuando la necesitás.

        ## Por qué funciona

        - El chat conserva su ritmo.
        - La lectura tiene jerarquía.
        - El tema es local al visor.

        > El contenido es protagonista; el botón de ojo permanece sutil.

        ```swift
        let experiencia = "fluida"
        ```
        """,
        timestamp: 1_785_000_000_000
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Conversación de prueba")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(AppTheme.ink)

            Button {
                viewModel.present(document)
            } label: {
                ExplanationLauncher(document: document)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("explanation-open-explainer-ui-test")

            TextField("Mensaje", text: .constant(""))
                .textFieldStyle(.plain)
                .padding(12)
                .background(AppTheme.inputSurface)
                .accessibilityIdentifier("explanation-background-composer")

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppTheme.backgroundSolid.ignoresSafeArea())
        .fullScreenCover(
            isPresented: Binding(
                get: { viewModel.isPresented },
                set: { if !$0 { viewModel.dismiss() } }
            )
        ) {
            ExplanationViewerSheet(viewModel: viewModel)
        }
    }
}
#endif
