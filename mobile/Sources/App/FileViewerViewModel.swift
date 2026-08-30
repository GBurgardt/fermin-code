import Foundation

enum KycodeFilePreviewKind: String, Codable, Equatable, Sendable {
    case code
    case markdown
    case json
    case text
}

enum KycodeFileTypeDetector {
    private static let languages: [String: String] = [
        "c": "c", "cc": "cpp", "cpp": "cpp", "css": "css", "go": "go",
        "h": "c", "hpp": "cpp", "html": "html", "java": "java",
        "js": "javascript", "jsx": "javascript", "kt": "kotlin",
        "m": "objective-c", "mm": "objective-cpp", "php": "php",
        "py": "python", "rb": "ruby", "rs": "rust", "sh": "shell",
        "sql": "sql", "swift": "swift", "toml": "toml", "ts": "typescript",
        "tsx": "typescript", "vue": "vue", "xml": "xml", "yaml": "yaml",
        "yml": "yaml", "zsh": "shell"
    ]

    /// Add another supported code type by registering its lower-cased extension
    /// and display language here. Unknown UTF-8 files safely remain plain text.
    static func detect(path: String) -> (kind: KycodeFilePreviewKind, language: String?) {
        let extensionName = URL(fileURLWithPath: path).pathExtension.lowercased()
        if ["md", "markdown", "mdown"].contains(extensionName) {
            return (.markdown, nil)
        }
        if ["json", "jsonc"].contains(extensionName) {
            return (.json, "json")
        }
        if let language = languages[extensionName] {
            return (.code, language)
        }
        return (.text, nil)
    }
}

struct KycodeFilePreview: Codable, Equatable, Sendable {
    let path: String
    let name: String
    let content: String
    let kind: KycodeFilePreviewKind
    let language: String?
    let sizeBytes: Int

    var resolvedKind: KycodeFilePreviewKind {
        kind == .text ? KycodeFileTypeDetector.detect(path: path).kind : kind
    }

    var resolvedLanguage: String? {
        language ?? KycodeFileTypeDetector.detect(path: path).language
    }
}

enum FileViewerState: Equatable {
    case idle
    case loading
    case success(KycodeFilePreview)
    case failure(String)
}

enum FileViewerPreviewError: LocalizedError, Equatable {
    case notFound
    case timedOut
    case tooLarge
    case unsupported
    case message(String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "El archivo no existe o ya no está disponible."
        case .timedOut:
            return "La Mac tardó demasiado en responder. Volvé a intentarlo."
        case .tooLarge:
            return "El archivo supera el límite de 10 MB."
        case .unsupported:
            return "Este formato no puede mostrarse como texto."
        case .message(let message):
            return message.isEmpty ? "No se pudo abrir el archivo." : message
        }
    }
}

actor FileViewerPreviewCache {
    static let shared = FileViewerPreviewCache()

    private let capacity: Int
    private var entries: [String: KycodeFilePreview] = [:]
    private var recency: [String] = []

    init(capacity: Int = 16) {
        self.capacity = max(1, capacity)
    }

    func preview(for path: String) -> KycodeFilePreview? {
        guard let preview = entries[path] else { return nil }
        recency.removeAll(where: { $0 == path })
        recency.append(path)
        return preview
    }

    func insert(_ preview: KycodeFilePreview) {
        entries[preview.path] = preview
        recency.removeAll(where: { $0 == preview.path })
        recency.append(preview.path)
        while recency.count > capacity {
            let oldest = recency.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }

    func removeAll() {
        entries.removeAll()
        recency.removeAll()
    }
}

@MainActor
final class FileViewerViewModel: ObservableObject {
    typealias Loader = @MainActor @Sendable (String) async throws -> KycodeFilePreview

    @Published private(set) var state: FileViewerState = .idle

    private let cache: FileViewerPreviewCache
    private let loader: Loader
    private let timeoutNanoseconds: UInt64

    init(
        cache: FileViewerPreviewCache = .shared,
        timeout: TimeInterval = 8,
        loader: @escaping Loader
    ) {
        self.cache = cache
        self.timeoutNanoseconds = UInt64(max(0.01, timeout) * 1_000_000_000)
        self.loader = loader
    }

    func load(path: String, forceRefresh: Bool = false) async {
        if !forceRefresh, let cached = await cache.preview(for: path) {
            state = .success(cached)
            return
        }

        state = .loading
        do {
            let preview = try await withThrowingTaskGroup(of: KycodeFilePreview.self) { group in
                group.addTask { [loader] in
                    try await loader(path)
                }
                group.addTask { [timeoutNanoseconds] in
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    throw FileViewerPreviewError.timedOut
                }
                guard let first = try await group.next() else {
                    throw FileViewerPreviewError.message("La respuesta del archivo llegó vacía.")
                }
                group.cancelAll()
                return first
            }
            guard !Task.isCancelled else { return }
            await cache.insert(preview)
            state = .success(preview)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            state = .failure(Self.userMessage(for: error))
        }
    }

    static func userMessage(for error: Error) -> String {
        if let viewerError = error as? FileViewerPreviewError {
            return viewerError.localizedDescription
        }
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return FileViewerPreviewError.timedOut.localizedDescription
        }
        let nsError = error as NSError
        switch nsError.code {
        case 404:
            return FileViewerPreviewError.notFound.localizedDescription
        case 408, 504:
            return FileViewerPreviewError.timedOut.localizedDescription
        case 413:
            return FileViewerPreviewError.tooLarge.localizedDescription
        case 415:
            return FileViewerPreviewError.unsupported.localizedDescription
        default:
            return FileViewerPreviewError.message(nsError.localizedDescription).localizedDescription
        }
    }
}

enum FileViewerTokenKind: Equatable {
    case plain
    case keyword
    case string
    case number
    case comment
}

struct FileViewerCodeSegment: Equatable {
    let text: String
    let kind: FileViewerTokenKind
}

enum FileViewerSyntaxHighlighter {
    private static let keywords = Set([
        "actor", "async", "await", "break", "case", "catch", "class", "const",
        "continue", "default", "defer", "do", "else", "enum", "export", "extends",
        "false", "final", "for", "func", "function", "guard", "if", "import", "in",
        "interface", "let", "nil", "null", "private", "protocol", "public", "return",
        "self", "static", "struct", "super", "switch", "throw", "throws", "true",
        "try", "typealias", "var", "while"
    ])

    /// Tokenization is deliberately lightweight and line-based so 1,000+ line
    /// files stay smooth. Add language-specific words to `keywords`; unknown
    /// languages keep this safe generic highlighter and never lose content.
    static func segments(for line: String, language: String?) -> [FileViewerCodeSegment] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("#") {
            return [FileViewerCodeSegment(text: line, kind: .comment)]
        }

        var output: [FileViewerCodeSegment] = []
        var current = ""
        var index = line.startIndex

        func flushPlain() {
            guard !current.isEmpty else { return }
            output.append(FileViewerCodeSegment(text: current, kind: .plain))
            current = ""
        }

        while index < line.endIndex {
            let character = line[index]
            if character == "\"" || character == "'" {
                flushPlain()
                let quote = character
                var token = String(character)
                index = line.index(after: index)
                var escaped = false
                while index < line.endIndex {
                    let next = line[index]
                    token.append(next)
                    index = line.index(after: index)
                    if next == quote && !escaped { break }
                    escaped = next == "\\" && !escaped
                    if next != "\\" { escaped = false }
                }
                output.append(FileViewerCodeSegment(text: token, kind: .string))
                continue
            }
            if character.isLetter || character == "_" {
                flushPlain()
                var token = String(character)
                index = line.index(after: index)
                while index < line.endIndex {
                    let next = line[index]
                    guard next.isLetter || next.isNumber || next == "_" else { break }
                    token.append(next)
                    index = line.index(after: index)
                }
                output.append(
                    FileViewerCodeSegment(
                        text: token,
                        kind: keywords.contains(token) ? .keyword : .plain
                    )
                )
                continue
            }
            if character.isNumber {
                flushPlain()
                var token = String(character)
                index = line.index(after: index)
                while index < line.endIndex {
                    let next = line[index]
                    guard next.isNumber || next == "." || next == "_" else { break }
                    token.append(next)
                    index = line.index(after: index)
                }
                output.append(FileViewerCodeSegment(text: token, kind: .number))
                continue
            }
            current.append(character)
            index = line.index(after: index)
        }
        flushPlain()
        return output.isEmpty ? [FileViewerCodeSegment(text: line, kind: .plain)] : output
    }
}
