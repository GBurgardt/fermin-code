import SwiftUI

struct KycodeFileReference: Identifiable, Hashable, Sendable {
    let path: String
    let displayName: String

    var id: String { path }
}

enum KycodeFileLinkifier {
    static let viewerScheme = "kycode-file"

    private static let webSchemes = ["http", "https", "mailto", "tel"]
    private static let supportedExtensions = [
        "c", "cc", "cpp", "css", "go", "h", "hpp", "html", "java", "js", "jsx",
        "json", "jsonc", "kt", "m", "markdown", "md", "mdown", "mm", "php", "py",
        "rb", "rs", "sh", "sql", "swift", "text", "toml", "ts", "tsx", "txt",
        "vue", "xml", "yaml", "yml", "zsh"
    ]

    private static let explicitLinkExpression = try! NSRegularExpression(
        pattern: #"(?<!!)\[([^\]\n]+)\]\(([^)\n]+)\)"#
    )
    private static let bareAbsolutePathExpression = try! NSRegularExpression(
        pattern: #"(?<![\w\]\("'`])((?:file://)?/(?:Users|Volumes|Applications|Library|System|private|tmp|opt|usr|var)/[^\s<>"')\]]+?\.(?:\#(supportedExtensions.joined(separator: "|")))(?::\d+(?::\d+)?|#L\d+(?:C\d+)?)?)"#,
        options: [.caseInsensitive]
    )
    private static let lineSuffixExpression = try! NSRegularExpression(
        pattern: #"(?::\d+(?::\d+)?|#L\d+(?:C\d+)?)$"#,
        options: [.caseInsensitive]
    )

    static func reference(for destination: String, basePath: String?) -> KycodeFileReference? {
        var raw = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("<"), raw.hasSuffix(">"), raw.count >= 2 {
            raw.removeFirst()
            raw.removeLast()
        }
        raw = raw.removingPercentEncoding ?? raw
        guard !raw.isEmpty else { return nil }

        if let components = URLComponents(string: raw),
           let scheme = components.scheme?.lowercased(),
           webSchemes.contains(scheme) {
            return nil
        }
        if let viewerReference = reference(fromViewerURL: URL(string: raw)) {
            return viewerReference
        }

        if raw.lowercased().hasPrefix("file://") {
            guard let url = URL(string: raw) else { return nil }
            raw = url.path
        }
        raw = removingLineSuffix(from: raw)

        let candidate: String
        if raw.hasPrefix("/") {
            candidate = URL(fileURLWithPath: raw).standardizedFileURL.path
        } else {
            guard looksLikeRelativeFile(raw), let basePath, !basePath.isEmpty else { return nil }
            candidate = URL(fileURLWithPath: basePath)
                .appendingPathComponent(raw)
                .standardizedFileURL
                .path
        }

        return KycodeFileReference(
            path: candidate,
            displayName: URL(fileURLWithPath: candidate).lastPathComponent
        )
    }

    static func viewerURL(for reference: KycodeFileReference) -> URL? {
        var components = URLComponents()
        components.scheme = viewerScheme
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "path", value: reference.path)]
        return components.url
    }

    static func reference(fromViewerURL url: URL?) -> KycodeFileReference? {
        guard let url, url.scheme?.lowercased() == viewerScheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let path = components.queryItems?.first(where: { $0.name == "path" })?.value,
              !path.isEmpty else {
            return nil
        }
        return KycodeFileReference(
            path: path,
            displayName: URL(fileURLWithPath: path).lastPathComponent
        )
    }

    static func prepareMarkdown(_ source: String, basePath: String?) -> String {
        var insideFence = false
        return source
            .components(separatedBy: "\n")
            .map { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                    insideFence.toggle()
                    return line
                }
                guard !insideFence else { return line }
                return transformOutsideInlineCode(line, basePath: basePath)
            }
            .joined(separator: "\n")
    }

    private static func transformOutsideInlineCode(_ line: String, basePath: String?) -> String {
        let parts = line.split(separator: "`", omittingEmptySubsequences: false)
        return parts.enumerated().map { index, part in
            let value = String(part)
            guard index.isMultiple(of: 2) else { return value }
            return linkifyBarePaths(
                in: rewriteExplicitLinks(in: value, basePath: basePath),
                basePath: basePath
            )
        }.joined(separator: "`")
    }

    private static func rewriteExplicitLinks(in value: String, basePath: String?) -> String {
        var output = value
        let matches = explicitLinkExpression.matches(
            in: value,
            range: NSRange(value.startIndex..., in: value)
        )
        for match in matches.reversed() {
            guard let fullRange = Range(match.range(at: 0), in: output),
                  let labelRange = Range(match.range(at: 1), in: value),
                  let destinationRange = Range(match.range(at: 2), in: value),
                  let reference = reference(
                    for: String(value[destinationRange]),
                    basePath: basePath
                  ),
                  let url = viewerURL(for: reference) else {
                continue
            }
            output.replaceSubrange(
                fullRange,
                with: "[\(value[labelRange])](\(url.absoluteString))"
            )
        }
        return output
    }

    private static func linkifyBarePaths(in value: String, basePath: String?) -> String {
        var output = value
        let protectedLinkRanges = explicitLinkExpression
            .matches(in: value, range: NSRange(value.startIndex..., in: value))
            .map(\.range)
        let matches = bareAbsolutePathExpression.matches(
            in: value,
            range: NSRange(value.startIndex..., in: value)
        )
        for match in matches.reversed() {
            guard !protectedLinkRanges.contains(where: {
                NSIntersectionRange($0, match.range(at: 1)).length > 0
            }) else {
                continue
            }
            guard let range = Range(match.range(at: 1), in: output) else { continue }
            let matched = String(output[range])
            guard let reference = reference(for: matched, basePath: basePath),
                  let url = viewerURL(for: reference) else {
                continue
            }
            output.replaceSubrange(range, with: "[\(matched)](\(url.absoluteString))")
        }
        return output
    }

    private static func removingLineSuffix(from value: String) -> String {
        let range = NSRange(value.startIndex..., in: value)
        return lineSuffixExpression.stringByReplacingMatches(
            in: value,
            range: range,
            withTemplate: ""
        )
    }

    private static func looksLikeRelativeFile(_ value: String) -> Bool {
        guard !value.hasPrefix("#"), !value.contains("://") else { return false }
        let extensionName = URL(fileURLWithPath: value).pathExtension.lowercased()
        return supportedExtensions.contains(extensionName)
    }
}

/// Standalone link primitive for file rows outside Markdown. Chat Markdown uses
/// the same custom URL contract so every entry point opens one shared viewer.
struct FileLink: View {
    let reference: KycodeFileReference
    let onOpen: (KycodeFileReference) -> Void

    var body: some View {
        Button {
            AppHaptics.shared.play(.conversationSelection)
            onOpen(reference)
        } label: {
            Label(reference.displayName, systemImage: "doc.text")
                .foregroundStyle(AppTheme.accent)
                .underline()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Abrir archivo \(reference.displayName)")
        .accessibilityHint("Muestra el archivo dentro de KyCode")
        .accessibilityAddTraits(.isLink)
    }
}
