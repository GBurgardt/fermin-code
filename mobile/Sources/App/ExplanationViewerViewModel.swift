import Combine
import SwiftUI

enum ExplanationViewerTheme: String, CaseIterable, Equatable, Sendable {
    case dark
    case light

    var accessibilityName: String {
        switch self {
        case .dark: return "Oscuro"
        case .light: return "Claro"
        }
    }

    var toggleIconName: String {
        switch self {
        case .dark: return "sun.max"
        case .light: return "moon"
        }
    }

    var toggleAccessibilityLabel: String {
        switch self {
        case .dark: return "Usar modo claro"
        case .light: return "Usar modo oscuro"
        }
    }

    var palette: KycodeDocumentReaderPalette {
        switch self {
        case .dark: return .dark
        case .light: return .light
        }
    }
}

struct KycodeDocumentReaderPalette {
    let background: Color
    let surface: Color
    let raisedSurface: Color
    let ink: Color
    let inkSoft: Color
    let inkMuted: Color
    let accent: Color
    let codeBackground: Color
    let codeInk: Color
    let codeAccent: Color
    let string: Color
    let number: Color
    let comment: Color

    static let dark = KycodeDocumentReaderPalette(
        background: Color(red: 0.027, green: 0.031, blue: 0.043),
        surface: Color(red: 0.055, green: 0.063, blue: 0.082),
        raisedSurface: Color(red: 0.094, green: 0.106, blue: 0.133),
        ink: Color(red: 0.969, green: 0.973, blue: 0.980),
        inkSoft: Color(red: 0.831, green: 0.843, blue: 0.871),
        inkMuted: Color(red: 0.667, green: 0.690, blue: 0.737),
        accent: Color(red: 0.545, green: 0.573, blue: 1.000),
        codeBackground: Color(red: 0.047, green: 0.055, blue: 0.071),
        codeInk: Color(red: 0.945, green: 0.953, blue: 0.973),
        codeAccent: Color(red: 0.596, green: 0.620, blue: 1.000),
        string: Color(red: 0.52, green: 0.92, blue: 0.66),
        number: Color(red: 0.48, green: 0.84, blue: 0.96),
        comment: Color(red: 0.68, green: 0.71, blue: 0.77)
    )

    static let light = KycodeDocumentReaderPalette(
        background: Color(red: 0.976, green: 0.969, blue: 0.945),
        surface: Color(red: 0.996, green: 0.992, blue: 0.980),
        raisedSurface: Color(red: 0.929, green: 0.918, blue: 0.886),
        ink: Color(red: 0.086, green: 0.090, blue: 0.106),
        inkSoft: Color(red: 0.204, green: 0.212, blue: 0.239),
        inkMuted: Color(red: 0.310, green: 0.325, blue: 0.370),
        accent: Color(red: 0.247, green: 0.275, blue: 0.698),
        codeBackground: Color(red: 0.047, green: 0.055, blue: 0.071),
        codeInk: Color(red: 0.94, green: 0.95, blue: 0.98),
        codeAccent: Color(red: 0.596, green: 0.620, blue: 1.000),
        string: Color(red: 0.42, green: 0.88, blue: 0.58),
        number: Color(red: 0.42, green: 0.79, blue: 0.96),
        comment: Color(red: 0.69, green: 0.72, blue: 0.78)
    )
}

enum KycodeReaderDocumentKind: String, Equatable, Sendable {
    case explanation
    case improvedPrompt

    var title: String {
        switch self {
        case .explanation: return "Explicación"
        case .improvedPrompt: return "Prompt mejorado"
        }
    }

    var launcherTitle: String {
        switch self {
        case .explanation: return "Ver explicación"
        case .improvedPrompt: return "Ver prompt mejorado"
        }
    }

    var launcherSubtitle: String {
        switch self {
        case .explanation: return "Abrir lector"
        case .improvedPrompt: return "Comparar en el lector"
        }
    }

    var iconName: String {
        switch self {
        case .explanation: return "eye"
        case .improvedPrompt: return "wand.and.stars"
        }
    }

    var metadataLabel: String {
        switch self {
        case .explanation: return "LECTURA"
        case .improvedPrompt: return "PROMPT"
        }
    }

    var copyAccessibilityLabel: String {
        switch self {
        case .explanation: return "Copiar explicación"
        case .improvedPrompt: return "Copiar prompt mejorado"
        }
    }
}

struct KycodeReaderDocument: Identifiable, Equatable, Sendable {
    let id: String
    let messageId: String
    let kind: KycodeReaderDocumentKind
    let content: String
    let timestamp: Double

    var title: String { kind.title }
}

enum KycodeExplanationPolicy {
    private static let unavailableContents = Set([
        "generating explanation...",
        "explanation canceled.",
        "explanation cancelled.",
        "generando explicación...",
        "explicación cancelada.",
    ])

    static func document(for message: KycodeMessage) -> KycodeReaderDocument? {
        guard message.id.lowercased().hasPrefix("explainer-"),
              message.role.lowercased() != "user" else {
            return nil
        }

        let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedContent = content.lowercased()
        let normalizedStatus = message.status?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""

        guard !content.isEmpty,
              !unavailableContents.contains(normalizedContent),
              !normalizedStatus.contains("error"),
              !normalizedStatus.contains("fail"),
              !normalizedStatus.contains("cancel") else {
            return nil
        }

        return KycodeReaderDocument(
            id: message.id,
            messageId: message.id,
            kind: .explanation,
            content: content,
            timestamp: message.timestamp
        )
    }

    static func documents(in messages: [KycodeMessage]) -> [KycodeReaderDocument] {
        messages.compactMap(document(for:))
    }
}

enum KycodeImprovedPromptPolicy {
    static func document(
        for message: KycodeMessage,
        sessionImprovedPrompt: String? = nil
    ) -> KycodeReaderDocument? {
        guard message.role.lowercased() == "user" else { return nil }

        let original = normalized(message.originalPrompt)
            ?? normalized(message.content)
        let improved = normalized(message.improvedPrompt)
            ?? normalized(message.transformedPrompt)
            ?? normalized(sessionImprovedPrompt)

        guard let original,
              let improved,
              original != improved else {
            return nil
        }

        return KycodeReaderDocument(
            id: "improved-prompt-\(message.id)",
            messageId: message.id,
            kind: .improvedPrompt,
            content: improved,
            timestamp: message.timestamp
        )
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

@MainActor
final class ExplanationViewerViewModel: ObservableObject {
    @Published private(set) var latestDocument: KycodeReaderDocument?
    @Published private(set) var presentedDocument: KycodeReaderDocument?
    @Published private(set) var isPresented = false
    @Published var theme: ExplanationViewerTheme = .light

    var hasAvailableExplanation: Bool {
        latestDocument != nil
    }

    func sync(messages: [KycodeMessage]) {
        let documents = KycodeExplanationPolicy.documents(in: messages)
        latestDocument = documents.last

        guard let presentedDocument,
              let refreshed = documents.last(where: { $0.id == presentedDocument.id }) else {
            return
        }
        self.presentedDocument = refreshed
    }

    func present(_ document: KycodeReaderDocument) {
        presentedDocument = document
        isPresented = true
    }

    func presentLatest() {
        guard let latestDocument else { return }
        present(latestDocument)
    }

    func dismiss() {
        isPresented = false
    }

    func toggleTheme() {
        theme = theme == .dark ? .light : .dark
    }
}

enum TranscriptFloatingControlLayout {
    static let minimumBottomPadding: CGFloat = 20
    static let composerGap: CGFloat = 10
    static let transcriptTailGap: CGFloat = 24

    static func scrollButtonBottomPadding(composerHeight: CGFloat) -> CGFloat {
        max(minimumBottomPadding, composerHeight + composerGap)
    }

    static func transcriptTailClearance(
        composerHeight: CGFloat,
        baseline: CGFloat
    ) -> CGFloat {
        max(baseline, max(0, composerHeight) + transcriptTailGap)
    }
}
