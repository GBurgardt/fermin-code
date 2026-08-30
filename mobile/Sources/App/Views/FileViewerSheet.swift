import SwiftUI

struct FileViewerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: FileViewerViewModel
    @State private var theme: ExplanationViewerTheme = .dark

    let reference: KycodeFileReference

    private var palette: KycodeDocumentReaderPalette {
        theme.palette
    }

    init(
        reference: KycodeFileReference,
        cache: FileViewerPreviewCache = .shared,
        loader: @escaping FileViewerViewModel.Loader
    ) {
        self.reference = reference
        _viewModel = StateObject(
            wrappedValue: FileViewerViewModel(cache: cache, loader: loader)
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.state {
                case .idle, .loading:
                    loadingView
                case .success(let preview):
                    previewView(preview)
                case .failure(let message):
                    errorView(message)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(palette.background)
            .navigationTitle(reference.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(palette.surface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(theme == .dark ? .dark : .light, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    fileIcon
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        AppHaptics.shared.play(.conversationSelection)
                        withAnimation(.easeInOut(duration: 0.20)) {
                            theme = theme == .dark ? .light : .dark
                        }
                    } label: {
                        Image(systemName: theme.toggleIconName)
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 36, height: 36)
                    }
                    .foregroundStyle(palette.inkSoft)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityLabel(theme.toggleAccessibilityLabel)
                    .accessibilityValue(theme.accessibilityName)
                    .accessibilityIdentifier("file-viewer-theme-toggle")

                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .frame(width: 36, height: 36)
                    }
                    .foregroundStyle(palette.inkSoft)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityLabel("Cerrar visor")
                    .accessibilityIdentifier("file-viewer-close")
                }
            }
        }
        .accessibilityIdentifier("file-viewer-sheet")
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(.scrolls)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .animation(.easeInOut(duration: 0.20), value: theme)
        .task(id: reference.path) {
            await viewModel.load(path: reference.path)
        }
    }

    private var fileIcon: some View {
        Image(systemName: "doc.text")
            .foregroundStyle(palette.accent)
            .accessibilityHidden(true)
    }

    private var loadingView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
                .tint(palette.accent)
            Text("Abriendo \(reference.displayName)…")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(palette.inkSoft)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Abriendo archivo")
    }

    private func errorView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("No se pudo abrir", systemImage: "doc.badge.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("Reintentar") {
                Task {
                    await viewModel.load(path: reference.path, forceRefresh: true)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(palette.accent)
        }
    }

    @ViewBuilder
    private func previewView(_ preview: KycodeFilePreview) -> some View {
        VStack(spacing: 0) {
            metadataBar(preview)
            switch preview.resolvedKind {
            case .markdown:
                FileViewerMarkdownContent(content: preview.content, palette: palette)
            case .code, .json:
                FileViewerCodeContent(
                    content: preview.content,
                    language: preview.resolvedLanguage
                        ?? (preview.resolvedKind == .json ? "json" : nil),
                    palette: palette
                )
            case .text:
                FileViewerPlainTextContent(content: preview.content, palette: palette)
            }
        }
        .accessibilityIdentifier("file-viewer-content")
    }

    private func metadataBar(_ preview: KycodeFilePreview) -> some View {
        HStack(spacing: 10) {
            Text(preview.resolvedLanguage?.uppercased() ?? preview.resolvedKind.rawValue.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(palette.accent)
            Text(ByteCountFormatter.string(fromByteCount: Int64(preview.sizeBytes), countStyle: .file))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(palette.inkMuted)
            Spacer(minLength: 0)
            Button {
                UIPasteboard.general.string = preview.content
                AppHaptics.shared.play(.conversationSelection)
            } label: {
                Label("Copiar", systemImage: "doc.on.doc")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(palette.inkSoft)
            .accessibilityLabel("Copiar contenido")
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
        .background(palette.surface)
    }
}

#if DEBUG
/// Deterministic visual harness. It is reachable only when an explicit UI-test
/// environment flag is present and exercises the same FileLink → sheet →
/// ViewModel path used by production chat messages.
struct FileViewerUITestHarness: View {
    @State private var presentation: FileViewerUITestPresentation?

    let autoOpenMarkdown: Bool

    init(autoOpenMarkdown: Bool = false) {
        self.autoOpenMarkdown = autoOpenMarkdown
    }

    private var reference: KycodeFileReference {
        if autoOpenMarkdown {
            return KycodeFileReference(
                path: "/Users/qa/KyCode/README.md",
                displayName: "README.md"
            )
        }
        return KycodeFileReference(
            path: "/Users/qa/KyCode/FileViewerSheet.swift",
            displayName: "FileViewerSheet.swift"
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Visor de archivos")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(AppTheme.ink)
            Text("Referencia de archivo dentro de una respuesta")
                .font(.system(size: 14))
                .foregroundStyle(AppTheme.inkSoft)
            FileLink(reference: reference) {
                presentation = FileViewerUITestPresentation(
                    reference: $0,
                    startedAt: ContinuousClock.now
                )
            }
                .accessibilityIdentifier("file-viewer-test-link")
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(24)
        .background(AppTheme.backgroundSolid.ignoresSafeArea())
        .sheet(item: $presentation) { presentation in
            FileViewerUITestMeasuredSheet(
                reference: presentation.reference,
                startedAt: presentation.startedAt
            )
        }
        .onAppear {
            guard autoOpenMarkdown, presentation == nil else { return }
            presentation = FileViewerUITestPresentation(
                reference: reference,
                startedAt: ContinuousClock.now
            )
        }
    }
}

private struct FileViewerUITestPresentation: Identifiable {
    let reference: KycodeFileReference
    let startedAt: ContinuousClock.Instant

    var id: String { reference.id }
}

private struct FileViewerUITestMeasuredSheet: View {
    let reference: KycodeFileReference
    let startedAt: ContinuousClock.Instant

    @State private var openLatencyMilliseconds: Int?

    var body: some View {
        FileViewerSheet(
            reference: reference,
            cache: FileViewerPreviewCache(capacity: 1)
        ) { path in
            try await Task.sleep(for: .milliseconds(90))
            if URL(fileURLWithPath: path).pathExtension.lowercased() == "md" {
                let content = """
                # Construir con claridad

                Una guía breve para convertir una idea compleja en una experiencia **simple, veloz y confiable**.

                ## Antes de empezar

                - Confirmá el objetivo y el resultado esperado.
                - Trabajá en pasos pequeños que puedas verificar.
                - Mantené la lectura cómoda incluso en documentos largos.

                > La interfaz debe sentirse tranquila: el contenido es protagonista y cada acción responde de inmediato.

                ### Ejemplo

                ```swift
                struct ReaderView: View {
                    let markdown: String

                    var body: some View {
                        ScrollView {
                            MarkdownDocument(markdown)
                        }
                    }
                }
                ```

                | Elemento | Resultado |
                | --- | --- |
                | Tipografía | Jerarquía clara |
                | Espaciado | Lectura respirable |

                Más detalles en [Apple Design](https://developer.apple.com/design/).
                """
                return KycodeFilePreview(
                    path: path,
                    name: "README.md",
                    content: content,
                    kind: .markdown,
                    language: nil,
                    sizeBytes: content.utf8.count
                )
            }
            let content = """
            import SwiftUI

            struct FileViewerSheet: View {
                @Environment(\\.dismiss) private var dismiss
                let filePath: String

                var body: some View {
                    ScrollView {
                        Text(filePath)
                    }
                }
            }
            """
            return KycodeFilePreview(
                path: path,
                name: "FileViewerSheet.swift",
                content: content,
                kind: .code,
                language: "swift",
                sizeBytes: content.utf8.count
            )
        }
        .overlay(alignment: .bottomTrailing) {
            if URL(fileURLWithPath: reference.path).pathExtension.lowercased() != "md",
               let openLatencyMilliseconds {
                Text("\(openLatencyMilliseconds) ms")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(AppTheme.accent)
                    .padding(8)
                    .accessibilityLabel("Latencia de apertura: \(openLatencyMilliseconds) ms")
                    .accessibilityIdentifier("file-viewer-open-latency")
            }
        }
        .onAppear {
            let duration = startedAt.duration(to: .now)
            openLatencyMilliseconds = Int(
                duration.components.seconds * 1_000
                    + duration.components.attoseconds / 1_000_000_000_000_000
            )
        }
    }
}
#endif

private struct FileViewerMarkdownContent: View {
    let content: String
    let palette: KycodeDocumentReaderPalette

    var body: some View {
        ScrollView {
            MarkdownBubbleText(
                markdown: content,
                isUser: false,
                presentation: .fileViewer,
                readerPalette: palette
            )
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(palette.background)
    }
}

private struct FileViewerPlainTextContent: View {
    let content: String
    let palette: KycodeDocumentReaderPalette

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(content)
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .foregroundStyle(palette.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .background(palette.background)
    }
}

private struct FileViewerCodeContent: View {
    let content: String
    let language: String?
    let palette: KycodeDocumentReaderPalette

    private var lines: [Substring] {
        content.split(separator: "\n", omittingEmptySubsequences: false)
    }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines.indices, id: \.self) { index in
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(index + 1)")
                            .foregroundStyle(palette.inkMuted.opacity(0.72))
                            .frame(width: 38, alignment: .trailing)
                            .accessibilityHidden(true)
                        highlightedText(String(lines[index]))
                    }
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .frame(minHeight: 21, alignment: .topLeading)
                    .id(index)
                }
            }
            .padding(.vertical, 14)
            .padding(.trailing, 18)
        }
        .background(palette.codeBackground)
    }

    private func highlightedText(_ line: String) -> Text {
        FileViewerSyntaxHighlighter
            .segments(for: line, language: language)
            .reduce(Text("")) { partial, segment in
                partial + Text(segment.text).foregroundColor(color(for: segment.kind))
            }
    }

    private func color(for kind: FileViewerTokenKind) -> Color {
        switch kind {
        case .plain:
            return palette.codeInk
        case .keyword:
            return palette.codeAccent
        case .string:
            return palette.string
        case .number:
            return palette.number
        case .comment:
            return palette.comment
        }
    }
}
