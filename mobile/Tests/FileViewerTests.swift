import XCTest
@testable import KyCode

private final class FileViewerMockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class FileViewerTests: XCTestCase {
    func testDetectsSwiftAsCode() {
        let type = KycodeFileTypeDetector.detect(path: "/tmp/App.swift")
        XCTAssertEqual(type.kind, .code)
        XCTAssertEqual(type.language, "swift")
    }

    func testDetectsJSON() {
        let type = KycodeFileTypeDetector.detect(path: "/tmp/config.json")
        XCTAssertEqual(type.kind, .json)
        XCTAssertEqual(type.language, "json")
    }

    func testDetectsMarkdownAndPlainTextFallback() {
        XCTAssertEqual(KycodeFileTypeDetector.detect(path: "/tmp/README.md").kind, .markdown)
        XCTAssertEqual(KycodeFileTypeDetector.detect(path: "/tmp/notes.unknown").kind, .text)
    }

    func testViewerURLRoundTripStripsSourceLineSuffix() {
        let reference = KycodeFileLinkifier.reference(
            for: "/Users/test/project/App.swift:42:7",
            basePath: nil
        )
        XCTAssertEqual(reference?.path, "/Users/test/project/App.swift")
        let url = reference.flatMap(KycodeFileLinkifier.viewerURL)
        XCTAssertEqual(KycodeFileLinkifier.reference(fromViewerURL: url), reference)
    }

    func testRelativeMarkdownFileResolvesAgainstProject() {
        let reference = KycodeFileLinkifier.reference(
            for: "docs/README.md",
            basePath: "/Users/test/project"
        )
        XCTAssertEqual(reference?.path, "/Users/test/project/docs/README.md")
    }

    func testWebURLIsNotClassifiedAsLocalFile() {
        XCTAssertNil(
            KycodeFileLinkifier.reference(
                for: "https://example.com/report.md",
                basePath: "/Users/test/project"
            )
        )
    }

    func testExplicitAndBareFilePathsBecomeViewerLinks() {
        let markdown = """
        [Reporte](docs/report.md)
        /Users/test/project/App.swift:18
        """
        let prepared = KycodeFileLinkifier.prepareMarkdown(
            markdown,
            basePath: "/Users/test/project"
        )
        XCTAssertEqual(prepared.components(separatedBy: "kycode-file://open").count - 1, 2)
        XCTAssertTrue(prepared.contains("Reporte"))
        XCTAssertTrue(prepared.contains("App.swift:18"))
    }

    func testPreparedFileLinkSurvivesSwiftMarkdownParsing() throws {
        let prepared = KycodeFileLinkifier.prepareMarkdown(
            "[FileViewerSheet.swift](/Users/test/FileViewerSheet.swift)",
            basePath: nil
        )
        let attributed = try AttributedString(
            markdown: prepared,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
        let links = attributed.runs.compactMap(\.link)

        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.scheme, KycodeFileLinkifier.viewerScheme)
    }

    func testCodeSpansAndFencesAreNeverLinkified() {
        let markdown = """
        `/Users/test/App.swift`
        ```
        /Users/test/App.swift
        ```
        """
        let prepared = KycodeFileLinkifier.prepareMarkdown(markdown, basePath: nil)
        XCTAssertEqual(prepared, markdown)
    }

    @MainActor
    func testThisMacFilePreviewUsesModernAuthenticatedEndpoint() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FileViewerMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        var observedRequests: [URLRequest] = []
        FileViewerMockURLProtocol.handler = { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            return (
                response,
                try JSONSerialization.data(withJSONObject: [
                    "ok": true,
                    "path": "/Users/test/project/README.md",
                    "name": "README.md",
                    "content": "# Local",
                    "kind": "markdown",
                    "language": NSNull(),
                    "sizeBytes": 7,
                ])
            )
        }
        defer {
            FileViewerMockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        let store = KycodeConnectionStore(
            urlSession: session,
            requestObserver: { observedRequests.append($0) }
        )
        store.baseURLInput = "http://this-mac.test:8792"
        store.authTokenInput = "local-token"

        let preview = try await store.fetchFilePreview(
            path: "/Users/test/project/README.md"
        )

        XCTAssertEqual(preview.content, "# Local")
        XCTAssertEqual(observedRequests.map(\.url?.path), ["/api/mobile/file-preview"])
        XCTAssertEqual(
            observedRequests.first?.value(forHTTPHeaderField: "Authorization"),
            "Bearer local-token"
        )
    }

    @MainActor
    func testPukyFilePreviewFallsBackToLegacyAuthenticatedEndpoint() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FileViewerMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        var observedRequests: [URLRequest] = []
        FileViewerMockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let isModernEndpoint = url.path == "/api/mobile/file-preview"
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: url,
                    statusCode: isModernEndpoint ? 404 : 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            if isModernEndpoint {
                return (response, Data(#"{"ok":false,"error":"not found"}"#.utf8))
            }
            return (
                response,
                try JSONSerialization.data(withJSONObject: [
                    "ok": true,
                    "path": "/Users/test/project/docs/report.md",
                    "content": "# Puky\nListo",
                ])
            )
        }
        defer {
            FileViewerMockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        let store = KycodeConnectionStore(
            urlSession: session,
            requestObserver: { observedRequests.append($0) }
        )
        store.baseURLInput = "https://desktop.example.com"
        store.authTokenInput = "puky-token"

        let preview = try await store.fetchFilePreview(
            path: "/Users/test/project/docs/report.md"
        )

        XCTAssertEqual(preview.name, "report.md")
        XCTAssertEqual(preview.kind, .markdown)
        XCTAssertEqual(preview.content, "# Puky\nListo")
        XCTAssertEqual(
            observedRequests.compactMap(\.url?.path),
            ["/api/mobile/file-preview", "/api/files/read-text"]
        )
        XCTAssertTrue(
            observedRequests.allSatisfy {
                $0.value(forHTTPHeaderField: "Authorization") == "Bearer puky-token"
            }
        )
    }

    @MainActor
    func testModernFileNotFoundDoesNotUseBroadLegacyFallback() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FileViewerMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        var requestCount = 0
        FileViewerMockURLProtocol.handler = { request in
            requestCount += 1
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            return (
                response,
                Data(#"{"ok":false,"error":"El archivo no existe o ya no está disponible."}"#.utf8)
            )
        }
        defer {
            FileViewerMockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        let store = KycodeConnectionStore(urlSession: session)
        store.baseURLInput = "http://this-mac.test:8792"
        store.authTokenInput = "local-token"

        do {
            _ = try await store.fetchFilePreview(path: "/Users/test/missing.md")
            XCTFail("Expected the modern endpoint's file-level 404.")
        } catch {
            XCTAssertEqual((error as NSError).code, 404)
            XCTAssertTrue(error.localizedDescription.contains("no existe"))
        }
        XCTAssertEqual(requestCount, 1)
    }

    @MainActor
    func testViewModelLoadsAndReusesBoundedCache() async {
        let cache = FileViewerPreviewCache(capacity: 2)
        var calls = 0
        let preview = Self.preview(path: "/tmp/App.swift", kind: .code)
        let viewModel = FileViewerViewModel(cache: cache) { _ in
            calls += 1
            return preview
        }

        await viewModel.load(path: preview.path)
        XCTAssertEqual(viewModel.state, .success(preview))
        await viewModel.load(path: preview.path)
        XCTAssertEqual(calls, 1)
    }

    @MainActor
    func testViewModelMaps404ToReadableError() async {
        let viewModel = FileViewerViewModel(cache: FileViewerPreviewCache()) { _ in
            throw NSError(
                domain: "KycodeMobile",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "not found"]
            )
        }
        await viewModel.load(path: "/tmp/missing.swift")
        guard case .failure(let message) = viewModel.state else {
            return XCTFail("Expected a failure state")
        }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("no existe"))
    }

    @MainActor
    func testViewModelTimesOutWithoutBlockingTheSheet() async {
        let viewModel = FileViewerViewModel(
            cache: FileViewerPreviewCache(),
            timeout: 0.02
        ) { _ in
            try await Task.sleep(nanoseconds: 500_000_000)
            return Self.preview(path: "/tmp/slow.txt", kind: .text)
        }
        await viewModel.load(path: "/tmp/slow.txt")
        guard case .failure(let message) = viewModel.state else {
            return XCTFail("Expected a timeout state")
        }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("tardó demasiado"))
    }

    func testSyntaxHighlighterPreservesAndClassifiesContent() {
        let line = #"let count = 42 // value"#
        let segments = FileViewerSyntaxHighlighter.segments(for: line, language: "swift")
        XCTAssertEqual(segments.map(\.text).joined(), line)
        XCTAssertTrue(segments.contains(where: { $0.text == "let" && $0.kind == .keyword }))
        XCTAssertTrue(segments.contains(where: { $0.text == "42" && $0.kind == .number }))
    }

    func testMarkdownViewerPreservesDocumentHierarchy() {
        let blocks = MarkdownMessageRenderer.blocks(
            for: """
            # Título

            Un párrafo con **jerarquía** y [un link](https://example.com).

            - Primer punto
            - Segundo punto

            > Una cita importante.

            ```swift
            let answer = 42
            ```
            """
        )

        XCTAssertTrue(blocks.contains { if case .heading(level: 1, _) = $0 { true } else { false } })
        XCTAssertEqual(blocks.filter { if case .paragraph = $0 { true } else { false } }.count, 1)
        XCTAssertEqual(blocks.filter { if case .list = $0 { true } else { false } }.count, 2)
        XCTAssertTrue(blocks.contains { if case .quote = $0 { true } else { false } })
        XCTAssertTrue(
            blocks.contains {
                if case .code(language: "swift", content: let content) = $0 {
                    return content.contains("answer")
                }
                return false
            }
        )
    }

    func testMarkdownViewerRecognizesTablesImagesAndRules() {
        let blocks = MarkdownMessageRenderer.blocks(
            for: """
            ![Arquitectura](https://example.com/architecture.png)

            | Elemento | Resultado |
            | --- | --- |
            | Tipografía | Clara |
            | Espaciado | Respirable |

            ---
            """
        )

        XCTAssertTrue(
            blocks.contains {
                if case .image(let alt, let url) = $0 {
                    return alt == "Arquitectura" && url?.absoluteString.hasPrefix("https://") == true
                }
                return false
            }
        )
        XCTAssertTrue(
            blocks.contains {
                if case .table(let headers, let rows) = $0 {
                    return headers.count == 2 && rows.count == 2
                }
                return false
            }
        )
        XCTAssertTrue(blocks.contains { if case .thematicBreak = $0 { true } else { false } })
    }

    @MainActor
    func testLongDocumentAndDismissibleSheetCanBeConstructed() {
        let content = (0...1_100).map { "line \($0)" }.joined(separator: "\n")
        let preview = KycodeFilePreview(
            path: "/tmp/long.txt",
            name: "long.txt",
            content: content,
            kind: .text,
            language: nil,
            sizeBytes: content.utf8.count
        )
        XCTAssertEqual(preview.content.components(separatedBy: "\n").count, 1_101)
        _ = FileViewerSheet(
            reference: KycodeFileReference(path: preview.path, displayName: preview.name)
        ) { _ in preview }
    }

    private static func preview(
        path: String,
        kind: KycodeFilePreviewKind
    ) -> KycodeFilePreview {
        KycodeFilePreview(
            path: path,
            name: URL(fileURLWithPath: path).lastPathComponent,
            content: "let answer = 42",
            kind: kind,
            language: kind == .code ? "swift" : nil,
            sizeBytes: 15
        )
    }
}
