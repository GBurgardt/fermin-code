import XCTest
@testable import KyCode

final class InteractiveLinksTests: XCTestCase {
    func testAcceptsHTTPAndHTTPSOnly() {
        XCTAssertEqual(
            KycodeInteractiveLink.webURL(from: "https://example.com/path")?.absoluteString,
            "https://example.com/path"
        )
        XCTAssertEqual(
            KycodeInteractiveLink.webURL(from: "http://example.com")?.absoluteString,
            "http://example.com"
        )
        XCTAssertNil(KycodeInteractiveLink.webURL(from: "file:///tmp/private.txt"))
        XCTAssertNil(KycodeInteractiveLink.webURL(from: "javascript:alert(1)"))
    }

    func testNormalizesWWWAddressToHTTPS() {
        XCTAssertEqual(
            KycodeInteractiveLink.webURL(from: "www.example.com/docs")?.absoluteString,
            "https://www.example.com/docs"
        )
    }

    func testAutolinksBareURL() {
        XCTAssertEqual(
            KycodeInteractiveLink.autolinkBareWebURLs(
                in: "Abrí https://example.com/docs para continuar."
            ),
            "Abrí <https://example.com/docs> para continuar."
        )
    }

    func testPreservesExistingMarkdownLink() {
        let source = "Abrí [la guía](https://example.com/docs)."
        XCTAssertEqual(
            KycodeInteractiveLink.autolinkBareWebURLs(in: source),
            source
        )
    }

    func testDoesNotLinkURLInsideInlineCode() {
        let source = "Ejecutá `curl https://example.com/docs`."
        XCTAssertEqual(
            KycodeInteractiveLink.autolinkBareWebURLs(in: source),
            source
        )
    }
}
