import XCTest
import ImageIO
import UIKit
@testable import KyCode

private final class KycodeMockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

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

private final class KycodeDeferredSendURLProtocol: URLProtocol {
    static var handler: ((KycodeDeferredSendURLProtocol, URLRequest) -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            fail(with: URLError(.badServerResponse))
            return
        }
        handler(self, request)
    }

    override func stopLoading() {}

    func succeed(data: Data) {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: nil,
                  headerFields: ["Content-Type": "application/json"]
              ) else {
            fail(with: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    func fail(with error: Error) {
        client?.urlProtocol(self, didFailWithError: error)
    }
}

private final class KycodeDeferredRequestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingRequest: KycodeDeferredSendURLProtocol?

    func hold(_ requestProtocol: KycodeDeferredSendURLProtocol) {
        lock.lock()
        pendingRequest = requestProtocol
        lock.unlock()
    }

    func succeed(data: Data) {
        takePendingRequest()?.succeed(data: data)
    }

    func fail(with error: Error) {
        takePendingRequest()?.fail(with: error)
    }

    private func takePendingRequest() -> KycodeDeferredSendURLProtocol? {
        lock.lock()
        defer { lock.unlock() }
        let requestProtocol = pendingRequest
        pendingRequest = nil
        return requestProtocol
    }
}

private final class KycodeSendProgressRaceController: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingAMessage: KycodeDeferredSendURLProtocol?
    private var pendingBUpload: KycodeDeferredSendURLProtocol?

    var hasPendingAMessage: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingAMessage != nil
    }

    var hasPendingBUpload: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingBUpload != nil
    }

    func handle(_ requestProtocol: KycodeDeferredSendURLProtocol, request: URLRequest) {
        let path = request.url?.path ?? ""
        if path.hasSuffix("/send-a/attachments") {
            requestProtocol.succeed(data: uploadData(path: "/uploads/send-a.png"))
            return
        }
        if path.hasSuffix("/send-a/message") {
            lock.lock()
            pendingAMessage = requestProtocol
            lock.unlock()
            return
        }
        if path.hasSuffix("/send-b/attachments") {
            lock.lock()
            pendingBUpload = requestProtocol
            lock.unlock()
            return
        }
        if path.hasSuffix("/send-b/message") {
            requestProtocol.succeed(data: Data(#"{"ok":true}"#.utf8))
            return
        }
        requestProtocol.fail(with: URLError(.badURL))
    }

    func releaseAMessage() {
        let requestProtocol: KycodeDeferredSendURLProtocol?
        lock.lock()
        requestProtocol = pendingAMessage
        pendingAMessage = nil
        lock.unlock()
        requestProtocol?.succeed(data: Data(#"{"ok":true}"#.utf8))
    }

    func releaseBUpload() {
        let requestProtocol: KycodeDeferredSendURLProtocol?
        lock.lock()
        requestProtocol = pendingBUpload
        pendingBUpload = nil
        lock.unlock()
        requestProtocol?.succeed(data: uploadData(path: "/uploads/send-b.png"))
    }

    func releaseAll() {
        releaseAMessage()
        releaseBUpload()
    }

    private func uploadData(path: String) -> Data {
        Data(
            "{\"ok\":true,\"path\":\"\(path)\",\"bytes\":9,\"mimeType\":\"image/png\"}".utf8
        )
    }
}

private func kycodeRequestBodyData(_ request: URLRequest) throws -> Data {
    if let body = request.httpBody {
        return body
    }
    guard let stream = request.httpBodyStream else {
        throw NSError(
            domain: "KyCodeTests.RequestBody",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Request has no HTTP body or body stream."]
        )
    }

    stream.open()
    defer { stream.close() }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 {
            throw stream.streamError ?? NSError(
                domain: "KyCodeTests.RequestBody",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not read HTTP body stream."]
            )
        }
        if count == 0 { break }
        result.append(buffer, count: count)
    }
    return result
}

final class ImageAttachmentPolicyTests: XCTestCase {
    func testConnectionFormRequiresCompleteInputsAndStopsDuplicateSubmissions() {
        XCTAssertFalse(
            KycodeConnectionFormPolicy.canSubmitRemoteHub(token: "  ", isConnecting: false)
        )
        XCTAssertTrue(
            KycodeConnectionFormPolicy.canSubmitRemoteHub(token: " token ", isConnecting: false)
        )
        XCTAssertFalse(
            KycodeConnectionFormPolicy.canSubmitRemoteHub(token: "token", isConnecting: true)
        )
        XCTAssertFalse(
            KycodeConnectionFormPolicy.canSubmitManual(
                baseURL: "",
                token: "token",
                isConnecting: false
            )
        )
        XCTAssertFalse(
            KycodeConnectionFormPolicy.canSubmitManual(
                baseURL: "desktop.example",
                token: "token",
                isConnecting: false
            )
        )
        XCTAssertFalse(
            KycodeConnectionFormPolicy.canSubmitManual(
                baseURL: "ftp://desktop.example",
                token: "token",
                isConnecting: false
            )
        )
        XCTAssertTrue(
            KycodeConnectionFormPolicy.canSubmitManual(
                baseURL: "https://desktop.example",
                token: "token",
                isConnecting: false
            )
        )
        XCTAssertTrue(
            KycodeConnectionFormPolicy.canSubmitManual(
                baseURL: " http://10.42.0.25:8791 ",
                token: "token",
                isConnecting: false
            )
        )
        XCTAssertNil(KycodeConnectionFormPolicy.manualBaseURLValidationMessage(""))
        XCTAssertEqual(
            KycodeConnectionFormPolicy.manualBaseURLValidationMessage("desktop.example"),
            KycodeConnectionFormPolicy.manualBaseURLGuidance
        )
        XCTAssertNil(
            KycodeConnectionFormPolicy.manualBaseURLValidationMessage(
                "https://desktop.example"
            )
        )
    }

    func testComposerSubmissionGateRejectsEmptyAndConcurrentSends() {
        XCTAssertFalse(
            KycodeComposerSubmissionPolicy.canBegin(
                isSending: false,
                isCreatingSubagent: false,
                isPreparingAttachments: false,
                hasPayload: false
            )
        )
        XCTAssertFalse(
            KycodeComposerSubmissionPolicy.canBegin(
                isSending: true,
                isCreatingSubagent: false,
                isPreparingAttachments: false,
                hasPayload: true
            )
        )
        XCTAssertFalse(
            KycodeComposerSubmissionPolicy.canBegin(
                isSending: false,
                isCreatingSubagent: true,
                isPreparingAttachments: false,
                hasPayload: true
            )
        )
        XCTAssertFalse(
            KycodeComposerSubmissionPolicy.canBegin(
                isSending: false,
                isCreatingSubagent: false,
                isPreparingAttachments: true,
                hasPayload: true
            )
        )
        XCTAssertTrue(
            KycodeComposerSubmissionPolicy.canBegin(
                isSending: false,
                isCreatingSubagent: false,
                isPreparingAttachments: false,
                hasPayload: true
            )
        )
    }

    func testAppBundleDisplayNameIsFerminCode() {
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
            "Fermín Code"
        )
    }

    func testDecodesExactDurableCommandAcknowledgement() throws {
        let data = Data(
            #"{"ok":true,"commandId":"cmd-1","commandState":"engineDurable","inserted":true,"durable":true,"queuedAt":1234}"#.utf8
        )

        let acknowledgement = try JSONDecoder().decode(KycodeDurableCommandAck.self, from: data)

        XCTAssertTrue(acknowledgement.ok)
        XCTAssertEqual(acknowledgement.commandId, "cmd-1")
        XCTAssertEqual(acknowledgement.commandState, .engineDurable)
        XCTAssertTrue(acknowledgement.inserted)
        XCTAssertTrue(acknowledgement.durable)
        XCTAssertEqual(acknowledgement.queuedAt, 1234)
    }

    func testDurableCommandTrackerAppliesReplayableTerminalFailureOnce() {
        var tracker = KycodeDurableCommandTracker()
        let context = KycodeTrackedCommandContext(
            operation: .sendMessage,
            windowId: "win-1",
            messageId: "message-1",
            sessionId: "session-1"
        )

        XCTAssertEqual(
            tracker.register(commandId: "cmd-1", state: .accepted, context: context),
            .pending(context)
        )
        XCTAssertEqual(
            tracker.apply(
                KycodeCommandStateChangedEvent(
                    commandId: "cmd-1",
                    state: .engineDurable,
                    error: nil
                )
            ),
            .pending(context)
        )
        XCTAssertEqual(
            tracker.apply(
                KycodeCommandStateChangedEvent(
                    commandId: "cmd-1",
                    state: .failed,
                    error: "child rejected command"
                )
            ),
            .failed(context, .failed, "child rejected command")
        )
        XCTAssertEqual(
            tracker.apply(
                KycodeCommandStateChangedEvent(
                    commandId: "cmd-1",
                    state: .failed,
                    error: "child rejected command"
                )
            ),
            .ignored
        )
        XCTAssertEqual(
            tracker.apply(
                KycodeCommandStateChangedEvent(
                    commandId: "replayed-untracked",
                    state: .cancelled,
                    error: nil
                )
            ),
            .failed(nil, .cancelled, nil)
        )
    }

    func testDurableCommandTrackerCorrelatesTerminalFailureArrivingBeforeSendAck() {
        var tracker = KycodeDurableCommandTracker()
        let context = KycodeTrackedCommandContext(
            operation: .sendMessage,
            windowId: "win-1",
            messageId: "message-1",
            sessionId: "session-1"
        )

        XCTAssertEqual(
            tracker.apply(
                KycodeCommandStateChangedEvent(
                    commandId: "cmd-race-send",
                    state: .failed,
                    error: "child rejected command"
                )
            ),
            .failed(nil, .failed, "child rejected command")
        )
        XCTAssertEqual(
            tracker.register(
                commandId: "cmd-race-send",
                state: .accepted,
                context: context
            ),
            .failed(context, .failed, "child rejected command")
        )
        XCTAssertEqual(
            tracker.apply(
                KycodeCommandStateChangedEvent(
                    commandId: "cmd-race-send",
                    state: .failed,
                    error: "child rejected command"
                )
            ),
            .ignored
        )
    }

    func testDurableCommandTrackerCorrelatesCompletionArrivingBeforeArchiveAck() {
        var tracker = KycodeDurableCommandTracker()
        let context = KycodeTrackedCommandContext(
            operation: .archive,
            windowId: "win-archive",
            messageId: nil,
            sessionId: "session-archive"
        )

        XCTAssertEqual(
            tracker.apply(
                KycodeCommandStateChangedEvent(
                    commandId: "cmd-race-archive",
                    state: .completed,
                    error: nil
                )
            ),
            .completed(nil)
        )
        XCTAssertEqual(
            tracker.register(
                commandId: "cmd-race-archive",
                state: .accepted,
                context: context
            ),
            .completed(context)
        )
    }

    func testFailedSSEDispatchStopsCursorBeforeLaterEvent() {
        var transaction = KycodeSSEDispatchTransaction()

        XCTAssertNil(transaction.commit(eventID: "40", applied: false))
        XCTAssertTrue(transaction.requiresReconnect)
        XCTAssertNil(transaction.commit(eventID: "41", applied: true))
    }

    func testSSESnapshotDecoderAcceptsMobileAndAuthoritativeShapes() throws {
        let session =
            #"{"windowId":"win-1","sessionId":"session-1","engine":"codex","projectKey":"project","displayName":"QA","sidecarMode":"local","activityStatus":"ready","messageCount":0,"updatedAt":1,"canSend":true}"#
        let mobile = try XCTUnwrap(
            KycodeSSESnapshotDecoder.decode(
                Data(#"{"ok":true,"now":10,"items":[\#(session)],"cursor":7}"#.utf8)
            )
        )
        let authoritative = try XCTUnwrap(
            KycodeSSESnapshotDecoder.decode(
                Data(
                    #"{"schemaVersion":1,"globalSequence":9,"generatedAt":11,"sessions":[\#(session)],"models":[]}"#.utf8
                )
            )
        )

        XCTAssertEqual(mobile.items.map(\.windowId), ["win-1"])
        XCTAssertEqual(mobile.cursor, 7)
        XCTAssertEqual(authoritative.items.map(\.windowId), ["win-1"])
        XCTAssertEqual(authoritative.cursor, 9)
        XCTAssertEqual(authoritative.now, 11)
    }

    func testFerminCapabilitiesRequireEachRustProfilesCanonicalEndpoint() {
        XCTAssertTrue(
            KycodeBackendCapabilityPolicy.isFerminCode(
                selectedProfileId: "personal",
                activeBaseURL: "https://relay.example.com/fermin-code"
            )
        )
        XCTAssertFalse(
            KycodeBackendCapabilityPolicy.isFerminCode(
                selectedProfileId: "personal",
                activeBaseURL: "https://relay.example.com/legacy-hub"
            )
        )
        XCTAssertTrue(
            KycodeBackendCapabilityPolicy.isFerminCode(
                selectedProfileId: "puky",
                activeBaseURL: "https://relay.example.com/fermin-code-puky"
            )
        )
        XCTAssertFalse(
            KycodeBackendCapabilityPolicy.isFerminCode(
                selectedProfileId: "puky",
                activeBaseURL: "https://relay.example.com/fermin-code"
            )
        )
        XCTAssertFalse(
            KycodeBackendCapabilityPolicy.isFerminCode(
                selectedProfileId: "personal",
                activeBaseURL: "https://relay.example.com/fermin-code-puky"
            )
        )
    }

    func testPersonalBonjourTransportKeepsLegacyCapabilitiesAndAcknowledgements() {
        XCTAssertFalse(
            KycodeBackendCapabilityPolicy.isFerminCode(
                selectedProfileId: "personal",
                activeBaseURL: "http://10.42.0.23:8787",
                offlineFallbackBaseURL: "https://relay.example.com/fermin-code"
            )
        )
    }

    func testCombinedProfileUsesEachSessionRouteTransport() {
        XCTAssertTrue(
            KycodeBackendCapabilityPolicy.isFerminCode(
                selectedProfileId: "all",
                routedProfileId: "personal",
                routedBaseURL: "https://relay.example.com/fermin-code"
            )
        )
        XCTAssertFalse(
            KycodeBackendCapabilityPolicy.isFerminCode(
                selectedProfileId: "all",
                routedProfileId: "personal",
                routedBaseURL: "http://secondary-mac.local:8787",
                offlineFallbackBaseURL: "https://relay.example.com/fermin-code"
            )
        )
        XCTAssertTrue(
            KycodeBackendCapabilityPolicy.isFerminCode(
                selectedProfileId: "all",
                routedProfileId: "puky",
                routedBaseURL: "https://relay.example.com/fermin-code-puky"
            )
        )
    }

    func testFerminEndpointMatchRejectsLookalikeHostsAndPaths() {
        XCTAssertFalse(
            KycodeBackendCapabilityPolicy.isFerminCode(
                selectedProfileId: "personal",
                activeBaseURL: "https://example.test/relay.example.com/fermin-code"
            )
        )
        XCTAssertFalse(
            KycodeBackendCapabilityPolicy.isFerminCode(
                selectedProfileId: "personal",
                activeBaseURL: "https://relay.example.com/fermin-code-legacy"
            )
        )
    }

    func testSSECursorIsMonotonicScopedAndAppliedAsLastEventID() throws {
        let suiteName = "KycodeSSECursorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let baseURL = "https://relay.example.com/fermin-code"

        XCTAssertNil(KycodeSSECursorStore.load(baseURL: baseURL, defaults: defaults))
        KycodeSSECursorStore.persist(eventID: "00042", baseURL: baseURL, defaults: defaults)
        KycodeSSECursorStore.persist(eventID: "41", baseURL: baseURL, defaults: defaults)
        KycodeSSECursorStore.persist(eventID: "opaque", baseURL: baseURL, defaults: defaults)

        XCTAssertEqual(
            KycodeSSECursorStore.load(baseURL: "\(baseURL)/", defaults: defaults),
            "42"
        )
        XCTAssertNil(
            KycodeSSECursorStore.load(
                baseURL: "https://relay.example.com/legacy-hub",
                defaults: defaults
            )
        )

        let streamURL = try XCTUnwrap(URL(string: "\(baseURL)/api/mobile/stream"))
        var request = URLRequest(url: streamURL)
        KycodeSSECursorStore.applyLastEventID(
            to: &request,
            baseURL: baseURL,
            defaults: defaults
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Last-Event-ID"), "42")

        KycodeSSECursorStore.clear(baseURL: baseURL, defaults: defaults)
        XCTAssertNil(KycodeSSECursorStore.load(baseURL: baseURL, defaults: defaults))
    }

    func testAttachmentControlRemainsAvailableWhileRecording() {
        XCTAssertTrue(
            KycodeImageAttachmentComposerPolicy.showsAttachmentControl(in: .idle)
        )
        XCTAssertTrue(
            KycodeImageAttachmentComposerPolicy.showsAttachmentControl(in: .recording),
            "Starting an audio recording must not remove the image attachment control."
        )
        XCTAssertFalse(
            KycodeImageAttachmentComposerPolicy.showsAttachmentControl(in: .transcribing)
        )
        XCTAssertTrue(KycodeImageAttachmentComposerPolicy.allowsCamera(in: .idle))
        XCTAssertFalse(
            KycodeImageAttachmentComposerPolicy.allowsCamera(in: .recording),
            "The library and clipboard stay available, but opening the camera must not interrupt active audio."
        )
    }

    func testAcceptsPNGWithinDesktopLimit() throws {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01])
        let draft = KycodeImageAttachmentDraft(
            id: "png",
            name: "sample.png",
            mimeType: "image/png",
            data: bytes
        )

        XCTAssertNoThrow(try KycodeImageAttachmentPolicy.validate([draft]))
        XCTAssertEqual(KycodeImageAttachmentPolicy.detectedMimeType(for: bytes), "image/png")
    }

    func testRejectsUnsupportedImageBytes() {
        let draft = KycodeImageAttachmentDraft(
            id: "heic",
            name: "sample.heic",
            mimeType: "image/heic",
            data: Data("not-an-image".utf8)
        )

        XCTAssertThrowsError(try KycodeImageAttachmentPolicy.validate([draft]))
    }

    func testRejectsMoreThanTenAttachments() {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0x01])
        let drafts = (0...KycodeImageAttachmentPolicy.maximumCount).map { index in
            KycodeImageAttachmentDraft(
                id: "\(index)",
                name: "\(index).jpg",
                mimeType: "image/jpeg",
                data: jpeg
            )
        }

        XCTAssertThrowsError(try KycodeImageAttachmentPolicy.validate(drafts))
    }

    func testAcceptsEveryDesktopImageFormat() throws {
        let fixtures: [(String, String, Data)] = [
            ("sample.png", "image/png", Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])),
            ("sample.jpg", "image/jpeg", Data([0xFF, 0xD8, 0xFF, 0x01])),
            ("sample.gif", "image/gif", Data("GIF89a".utf8)),
            (
                "sample.webp",
                "image/webp",
                Data([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50])
            ),
        ]

        for (index, fixture) in fixtures.enumerated() {
            let draft = KycodeImageAttachmentDraft(
                id: "\(index)",
                name: fixture.0,
                mimeType: fixture.1,
                data: fixture.2
            )
            XCTAssertNoThrow(try KycodeImageAttachmentPolicy.validate([draft]))
            XCTAssertEqual(KycodeImageAttachmentPolicy.detectedMimeType(for: fixture.2), fixture.1)
        }
    }

    func testRejectsAttachmentAboveTwentyMiB() {
        var oversizedPNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        oversizedPNG.append(Data(repeating: 0, count: KycodeImageAttachmentPolicy.maximumBytes))
        let draft = KycodeImageAttachmentDraft(
            id: "oversized",
            name: "oversized.png",
            mimeType: "image/png",
            data: oversizedPNG
        )

        XCTAssertThrowsError(try KycodeImageAttachmentPolicy.validate([draft]))
    }

    func testRejectsAttachmentsAboveFiftyMiBInTotal() {
        let bytes = Data(repeating: 0, count: 18 * 1024 * 1024)
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        png.append(bytes)
        let drafts = (0..<3).map { index in
            KycodeImageAttachmentDraft(
                id: "\(index)",
                name: "\(index).png",
                mimeType: "image/png",
                data: png
            )
        }

        XCTAssertThrowsError(try KycodeImageAttachmentPolicy.validate(drafts)) { error in
            XCTAssertEqual((error as NSError).code, 413)
            XCTAssertTrue(error.localizedDescription.contains("50 MiB"))
        }
    }

    func testDownsamplesLargeComposerImageBeforeKeepingItInMemory() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 3_000, height: 900))
        let image = renderer.image { context in
            UIColor.systemIndigo.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 3_000, height: 900))
        }
        let original = try XCTUnwrap(image.pngData())
        let optimized = KycodeImageAttachmentOptimizer.optimized(
            data: original,
            mimeType: "image/png",
            force: true
        )
        let source = try XCTUnwrap(CGImageSourceCreateWithData(optimized.data as CFData, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int)

        XCTAssertLessThanOrEqual(max(width, height), KycodeImageAttachmentOptimizer.maximumPixelDimension)
        XCTAssertLessThan(optimized.data.count, original.count)
        XCTAssertEqual(optimized.mimeType, "image/png")
    }

    func testDoesNotReencodeAnimatedDesktopFormats() {
        let gif = Data("GIF89a".utf8)
        let optimized = KycodeImageAttachmentOptimizer.optimized(
            data: gif,
            mimeType: "image/gif",
            force: true
        )
        XCTAssertEqual(optimized.data, gif)
        XCTAssertEqual(optimized.mimeType, "image/gif")
    }

    func testEncodesTextAndImageMessageWithDesktopAttachmentPath() throws {
        let payload = KycodeMessagePayload(
            message: "Analizá esta captura",
            clientMessageId: "mobile-user-contract-1",
            attachments: [
                KycodeMessageAttachmentPayload(
                    path: "/uploads/capture.png",
                    name: "capture.png",
                    size: 128,
                    mimeType: "image/png"
                ),
            ]
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any]
        )
        XCTAssertEqual(object["message"] as? String, "Analizá esta captura")
        XCTAssertEqual(object["clientMessageId"] as? String, "mobile-user-contract-1")
        XCTAssertEqual(object["fastModeEnabled"] as? Bool, false)
        let attachments = try XCTUnwrap(object["attachments"] as? [[String: Any]])
        XCTAssertEqual(attachments.first?["path"] as? String, "/uploads/capture.png")
    }

    func testEncodesImageOnlyMessage() throws {
        let payload = KycodeMessagePayload(
            message: "",
            attachments: [
                KycodeMessageAttachmentPayload(
                    path: "/uploads/only.webp",
                    name: "only.webp",
                    size: 64,
                    mimeType: "image/webp"
                ),
            ]
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any]
        )
        XCTAssertEqual(object["message"] as? String, "")
        XCTAssertEqual((object["attachments"] as? [[String: Any]])?.count, 1)
    }

    func testEncodesFastModeIntoDesktopBridgePayload() throws {
        let payload = KycodeMessagePayload(
            message: "Usá Fast mode",
            attachments: [],
            fastModeEnabled: true
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any]
        )
        XCTAssertEqual(object["fastModeEnabled"] as? Bool, true)
    }

    func testEncodesEditableSubagentParentNoteOnlyWhenProvided() throws {
        let stagedPayload = KycodeMessagePayload(
            message: "Implementá los tests",
            attachments: [],
            parentNotificationPrompt: "Aviso editado para la sesión padre"
        )
        let stagedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(stagedPayload)) as? [String: Any]
        )
        XCTAssertEqual(
            stagedObject["parentNotificationPrompt"] as? String,
            "Aviso editado para la sesión padre"
        )

        let ordinaryPayload = KycodeMessagePayload(message: "Mensaje normal", attachments: [])
        let ordinaryObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(ordinaryPayload)) as? [String: Any]
        )
        XCTAssertNil(ordinaryObject["parentNotificationPrompt"])
    }

    func testFastModePreferencePersistsAcrossLoads() throws {
        let suiteName = "KycodeFastModePreferenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(KycodeFastModePreference.load(from: defaults))
        KycodeFastModePreference.save(true, to: defaults)
        XCTAssertTrue(KycodeFastModePreference.load(from: defaults))
        KycodeFastModePreference.save(false, to: defaults)
        XCTAssertFalse(KycodeFastModePreference.load(from: defaults))
    }

    func testPromptImproverVariantDefaultsToStandardAndPersistsPerRuntime() throws {
        let suiteName = "KycodePromptImproverPreferenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(KycodePromptImproverPreferenceStore.load(from: defaults), .standard)
        KycodePromptImproverPreferenceStore.save(.motivational, to: defaults)
        XCTAssertEqual(KycodePromptImproverPreferenceStore.load(from: defaults), .motivational)
        XCTAssertNil(
            KycodePromptImproverPreferenceStore.load(profileId: "personal", from: defaults),
            "The ambiguous v1 scalar must not silently become Personal's value."
        )
        XCTAssertNil(
            KycodePromptImproverPreferenceStore.load(profileId: "puky", from: defaults),
            "The ambiguous v1 scalar must not silently become Puky's value."
        )
        XCTAssertEqual(
            KycodePromptImproverPreferenceStore.migrateLegacyValueIfNeeded(
                to: "personal",
                in: defaults
            ),
            .motivational
        )
        XCTAssertNil(defaults.string(forKey: KycodePromptImproverPreferenceStore.defaultsKey))
        XCTAssertEqual(
            KycodePromptImproverPreferenceStore.load(profileId: "personal", from: defaults),
            .motivational
        )
        XCTAssertNil(KycodePromptImproverPreferenceStore.load(profileId: "puky", from: defaults))

        KycodePromptImproverPreferenceStore.save(
            .standard,
            profileId: "personal",
            to: defaults
        )
        KycodePromptImproverPreferenceStore.save(
            .motivational,
            profileId: "puky",
            to: defaults
        )
        XCTAssertEqual(
            KycodePromptImproverPreferenceStore.load(profileId: "personal", from: defaults),
            .standard
        )
        XCTAssertEqual(
            KycodePromptImproverPreferenceStore.load(profileId: "puky", from: defaults),
            .motivational
        )
    }

    func testPendingSubagentDraftDecodesAsExplicitSendUntilChildStarts() throws {
        let staged = try JSONDecoder().decode(
            KycodePendingSubagentDraft.self,
            from: Data(
                #"{"displayMessage":"Revisá este flujo","parentNotificationPrompt":"Aviso al padre","childMessageSentAt":null}"#.utf8
            )
        )
        XCTAssertEqual(staged.displayMessage, "Revisá este flujo")
        XCTAssertTrue(staged.isWaitingForExplicitSend)

        let started = try JSONDecoder().decode(
            KycodePendingSubagentDraft.self,
            from: Data(
                #"{"displayMessage":"Revisá este flujo","parentNotificationPrompt":"Aviso al padre","childMessageSentAt":1785813000000}"#.utf8
            )
        )
        XCTAssertFalse(started.isWaitingForExplicitSend)
    }

    @MainActor
    func testPromptImproverVariantSynchronizesThroughAuthenticatedRuntimePreferenceEndpoint() async throws {
        let suiteName = "KycodePromptImproverEndpointTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KycodeMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        var observedRequests: [URLRequest] = []
        let sessionsData = try JSONEncoder().encode(
            KycodeSessionsEnvelope(
                ok: true,
                now: Date().timeIntervalSince1970 * 1_000,
                exportedAt: nil,
                items: []
            )
        )

        KycodeMockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            if url.path.hasSuffix("/api/mobile/preferences/prompt-improver") {
                XCTAssertEqual(request.httpMethod, "PUT")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
                let object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: kycodeRequestBodyData(request)) as? [String: Any]
                )
                XCTAssertEqual(object["variant"] as? String, "motivational")
                return (
                    response,
                    Data(#"{"ok":true,"preference":{"version":1,"variant":"motivational","updatedAt":"2026-08-03T21:00:00.000Z"},"variants":["standard","motivational"]}"#.utf8)
                )
            }
            return (response, sessionsData)
        }
        defer {
            KycodeMockURLProtocol.handler = nil
            session.invalidateAndCancel()
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = KycodeConnectionStore(
            urlSession: session,
            requestObserver: { observedRequests.append($0) },
            initialProfileIdOverride: "puky",
            runtimeSettingsDefaults: defaults
        )
        store.baseURLInput = "https://mock.kycode.test"
        store.authTokenInput = "test-token"
        await store.connect()
        XCTAssertTrue(store.isConnected)

        let didSave = await store.setPromptImproverVariant(.motivational)
        XCTAssertTrue(didSave)
        XCTAssertEqual(store.promptImproverVariant, .motivational)
        XCTAssertEqual(store.promptImproverVariantSyncState, .synchronized)
        XCTAssertEqual(
            KycodePromptImproverPreferenceStore.load(profileId: "puky", from: defaults),
            .motivational
        )
        XCTAssertTrue(
            observedRequests.contains(where: {
                $0.url?.path.hasSuffix("/api/mobile/preferences/prompt-improver") == true
            })
        )
        store.disconnect()
    }

    @MainActor
    func testPromptImproverVariantRapidChangesLeaveLatestIntentOnRuntime() async throws {
        let suiteName = "KycodePromptImproverRapidTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        KycodePromptImproverPreferenceStore.save(
            .standard,
            profileId: "puky",
            to: defaults
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KycodeMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let stateLock = NSLock()
        var completedVariants: [String] = []
        var simulatedServerVariant = KycodePromptImproverVariant.standard.rawValue
        let sessionsData = try JSONEncoder().encode(
            KycodeSessionsEnvelope(
                ok: true,
                now: Date().timeIntervalSince1970 * 1_000,
                exportedAt: nil,
                items: []
            )
        )

        KycodeMockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            guard url.path.hasSuffix("/api/mobile/preferences/prompt-improver") else {
                return (response, sessionsData)
            }

            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: kycodeRequestBodyData(request)) as? [String: Any]
            )
            let variant = try XCTUnwrap(object["variant"] as? String)
            if variant == KycodePromptImproverVariant.motivational.rawValue {
                Thread.sleep(forTimeInterval: 0.12)
            }
            stateLock.withLock {
                completedVariants.append(variant)
                simulatedServerVariant = variant
            }
            return (
                response,
                Data(
                    #"{"ok":true,"preference":{"version":1,"variant":"\#(variant)","updatedAt":"2026-08-16T11:15:00.000Z"},"variants":["standard","motivational"]}"#.utf8
                )
            )
        }
        defer {
            KycodeMockURLProtocol.handler = nil
            session.invalidateAndCancel()
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = KycodeConnectionStore(
            urlSession: session,
            initialProfileIdOverride: "puky",
            runtimeSettingsDefaults: defaults
        )
        store.baseURLInput = "https://mock.kycode.test"
        store.authTokenInput = "test-token"
        await store.connect()
        XCTAssertTrue(store.isConnected)

        async let firstChange = store.setPromptImproverVariant(.motivational)
        try await Task.sleep(for: .milliseconds(15))
        XCTAssertTrue(store.isUpdatingPromptImproverVariant)
        async let latestChange = store.setPromptImproverVariant(.standard)
        let results = await (firstChange, latestChange)

        XCTAssertTrue(results.0)
        XCTAssertTrue(results.1)
        XCTAssertFalse(store.isUpdatingPromptImproverVariant)
        XCTAssertEqual(store.promptImproverVariant, .standard)
        let (observedCompletedVariants, observedServerVariant) = stateLock.withLock {
            (completedVariants, simulatedServerVariant)
        }
        XCTAssertEqual(observedCompletedVariants, ["motivational", "standard"])
        XCTAssertEqual(observedServerVariant, "standard")
        XCTAssertEqual(
            KycodePromptImproverPreferenceStore.load(profileId: "puky", from: defaults),
            .standard
        )
        store.disconnect()
    }

    @MainActor
    func testSendMessageUploadsThenPostsTextAndImage() async throws {
        let requestCount = try await exerciseRealSendPath(expectedMessage: "Analizá esta captura")
        XCTAssertEqual(requestCount, 2)
    }

    @MainActor
    func testSendMessageUploadsThenPostsImageOnly() async throws {
        let requestCount = try await exerciseRealSendPath(expectedMessage: "")
        XCTAssertEqual(requestCount, 2)
    }

    @MainActor
    func testSendMessagePostsEnabledFastModeToDesktopBridge() async throws {
        let requestCount = try await exerciseRealSendPath(
            expectedMessage: "Respondé con Fast mode",
            fastModeEnabled: true
        )
        XCTAssertEqual(requestCount, 2)
    }

    @MainActor
    func testSendMessagePostsEditableSubagentParentNoteToDesktopBridge() async throws {
        let requestCount = try await exerciseRealSendPath(
            expectedMessage: "Iniciá el subagente",
            expectedParentNotificationPrompt: "Aviso personalizado al padre"
        )
        XCTAssertEqual(requestCount, 2)
    }

    @MainActor
    func testSendMessagePreservesOneFiveAndTenImages() async throws {
        for count in [1, 5, 10] {
            let requestCount = try await exerciseRealSendPath(
                expectedMessage: "Analizá \(count) imágenes",
                attachmentCount: count
            )
            XCTAssertEqual(requestCount, count + 1)
        }
    }

    @MainActor
    func testLateSendCannotClearTheNextWindowImageUploadProgress() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KycodeDeferredSendURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let race = KycodeSendProgressRaceController()
        KycodeDeferredSendURLProtocol.handler = { requestProtocol, request in
            race.handle(requestProtocol, request: request)
        }
        defer {
            race.releaseAll()
            KycodeDeferredSendURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        let store = KycodeConnectionStore(
            urlSession: session,
            initialProfileIdOverride: "puky"
        )
        store.baseURLInput = "https://mock.kycode.test"
        store.authTokenInput = "test-token"
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01])
        let attachmentA = KycodeImageAttachmentDraft(
            id: "send-a-image",
            name: "send-a.png",
            mimeType: "image/png",
            data: png
        )
        let attachmentB = KycodeImageAttachmentDraft(
            id: "send-b-image",
            name: "send-b.png",
            mimeType: "image/png",
            data: png
        )

        let sendA = Task { @MainActor in
            await store.sendMessage(
                windowId: "send-a",
                text: "Mensaje A",
                attachments: [attachmentA]
            )
        }
        for _ in 0..<200 where !race.hasPendingAMessage {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(race.hasPendingAMessage)
        let progressA = try XCTUnwrap(store.imageUploadProgress)
        XCTAssertEqual(progressA.windowId, "send-a")
        XCTAssertEqual(progressA.completed, 1)
        XCTAssertEqual(progressA.total, 1)

        let sendB = Task { @MainActor in
            await store.sendMessage(
                windowId: "send-b",
                text: "Mensaje B",
                attachments: [attachmentB]
            )
        }
        for _ in 0..<200 where !race.hasPendingBUpload {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(race.hasPendingBUpload)
        let progressB = try XCTUnwrap(store.imageUploadProgress)
        XCTAssertEqual(progressB.windowId, "send-b")
        XCTAssertNotEqual(progressB.sendId, progressA.sendId)
        XCTAssertEqual(progressB.completed, 0)
        XCTAssertEqual(progressB.total, 1)

        race.releaseAMessage()
        let resultA = await sendA.value
        XCTAssertTrue(resultA.sent, resultA.errorMessage ?? "A falló sin detalle")
        XCTAssertEqual(store.imageUploadProgress, progressB)

        race.releaseBUpload()
        let resultB = await sendB.value
        XCTAssertTrue(resultB.sent, resultB.errorMessage ?? "B falló sin detalle")
        XCTAssertNil(store.imageUploadProgress)
    }

    @MainActor
    func testAuthoritativeDetailSettlesOptimisticWorkingSummaryAfterReply() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KycodeMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let now = Date().timeIntervalSince1970 * 1_000
        var clientMessageId: String?
        var listReturnsStaleWorking = false

        func summary(
            messages: [KycodeMessage]?,
            activityStatus: String = "ready",
            runtimeStatus: String? = "WAITING"
        ) -> KycodeSessionSummary {
            KycodeSessionSummary(
                windowId: "test-window",
                sessionId: "test-session",
                engine: "codex",
                model: "gpt-5.6-luna",
                reasoningEffort: "high",
                providerSessionId: "thread-test",
                providerSessionPath: nil,
                projectKey: "fermin-code",
                projectPath: "/tmp/fermin-code",
                projectName: "Fermín Code",
                windowName: "Fermín Simulator Live",
                displayName: "Fermín Simulator Live",
                sidecarMode: "mobile",
                sidecarUrl: nil,
                activityStatus: activityStatus,
                runtimeStatus: runtimeStatus,
                runtimeStatusDetail: nil,
                features: nil,
                messageCount: messages?.count ?? (clientMessageId == nil ? 0 : 2),
                updatedAt: now + (clientMessageId == nil ? 0 : 2_000),
                createdAt: now - 1_000,
                rawPrompt: nil,
                originalPrompt: nil,
                improvedPrompt: nil,
                lastMessagePreview: messages?.last?.content,
                isMinimized: false,
                canSend: true,
                canControlFeatures: true,
                unsupportedReason: nil,
                messages: messages
            )
        }

        KycodeMockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            if url.path.hasSuffix("/message") {
                let object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: kycodeRequestBodyData(request)) as? [String: Any]
                )
                clientMessageId = try XCTUnwrap(object["clientMessageId"] as? String)
                return (response, Data(#"{"ok":true}"#.utf8))
            }
            if url.path.hasSuffix("/sessions/test-window") {
                let messages: [KycodeMessage]
                if let clientMessageId {
                    messages = [
                        KycodeMessage(
                            id: clientMessageId,
                            role: "user",
                            type: "text",
                            content: "Respondé exactamente SIMULATOR_OK",
                            originalPrompt: "Respondé exactamente SIMULATOR_OK",
                            transformedPrompt: nil,
                            improvedPrompt: nil,
                            timestamp: now + 500,
                            status: nil,
                            imageAttachments: nil
                        ),
                        KycodeMessage(
                            id: "assistant-final",
                            role: "assistant",
                            type: "text",
                            content: "SIMULATOR_OK",
                            originalPrompt: nil,
                            transformedPrompt: nil,
                            improvedPrompt: nil,
                            timestamp: now + 1_000,
                            status: nil,
                            imageAttachments: nil
                        ),
                    ]
                } else {
                    messages = []
                }
                return (
                    response,
                    try JSONEncoder().encode(
                        KycodeSessionDetailEnvelope(ok: true, now: now, item: summary(messages: messages))
                    )
                )
            }
            return (
                response,
                try JSONEncoder().encode(
                    KycodeSessionsEnvelope(
                        ok: true,
                        now: now,
                        exportedAt: nil,
                        items: [
                            summary(
                                messages: nil,
                                activityStatus: listReturnsStaleWorking ? "working" : "ready",
                                runtimeStatus: listReturnsStaleWorking ? "WORKING" : "WAITING"
                            )
                        ]
                    )
                )
            )
        }
        defer {
            KycodeMockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        let store = KycodeConnectionStore(
            urlSession: session,
            initialProfileIdOverride: "puky"
        )
        store.baseURLInput = "https://mock.kycode.test"
        store.authTokenInput = "test-token"
        await store.refreshSessionsNow()
        await store.refreshDetail(windowId: "test-window")

        let result = await store.sendMessage(
            windowId: "test-window",
            text: "Respondé exactamente SIMULATOR_OK"
        )
        XCTAssertTrue(result.sent, result.errorMessage ?? "El envío falló sin detalle")

        await store.refreshSessionsNow()
        await store.refreshDetail(windowId: "test-window")

        listReturnsStaleWorking = true
        await store.refreshSessionsNow()
        XCTAssertEqual(store.sessions.first?.activityStatus, "working")
        listReturnsStaleWorking = false
        await store.refreshDetail(windowId: "test-window")

        XCTAssertEqual(store.sessions.first?.activityStatus, "ready")
        XCTAssertEqual(store.sessions.first?.runtimeStatus, "WAITING")
        XCTAssertEqual(store.sessionDetails["test-window"]?.activityStatus, "ready")
        XCTAssertEqual(store.sessionDetails["test-window"]?.runtimeStatus, "WAITING")
        let settled = try XCTUnwrap(store.detail(for: "test-window"))
        XCTAssertFalse(
            KycodeSessionActivityPolicy.isProcessing(
                activityStatus: settled.activityStatus,
                runtimeStatus: settled.runtimeStatus
            )
        )
        XCTAssertEqual(settled.messages?.map(\.id), [clientMessageId, "assistant-final"].compactMap { $0 })
        store.disconnect()
    }

    @MainActor
    func testRestoresBoundedSessionSnapshotOnColdStoreInitialization() async throws {
        let defaultsKey = "kycode.mobile.cachedSessions.v1"
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: defaultsKey) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KycodeMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let summary = KycodeSessionSummary(
            windowId: "cached-window",
            sessionId: "cached-session",
            engine: "codex",
            model: "gpt-5.6-sol",
            reasoningEffort: "xhigh",
            providerSessionId: nil,
            providerSessionPath: "/private/path-that-must-not-be-cached",
            projectKey: "project",
            projectPath: "/tmp/project",
            projectName: "Proyecto",
            windowName: "Conversación recuperada",
            displayName: "Conversación recuperada",
            sidecarMode: "mobile",
            sidecarUrl: "https://private.example",
            activityStatus: "ready",
            runtimeStatus: "READY",
            runtimeStatusDetail: nil,
            features: nil,
            messageCount: 3,
            updatedAt: Date().timeIntervalSince1970 * 1_000,
            createdAt: nil,
            rawPrompt: String(repeating: "privado", count: 1_000),
            originalPrompt: nil,
            improvedPrompt: nil,
            lastMessagePreview: "Último mensaje visible",
            isMinimized: false,
            canSend: true,
            canControlFeatures: true,
            unsupportedReason: nil,
            messages: nil
        )
        let envelope = KycodeSessionsEnvelope(
            ok: true,
            now: Date().timeIntervalSince1970 * 1_000,
            exportedAt: nil,
            items: [summary]
        )
        let responseData = try JSONEncoder().encode(envelope)

        KycodeMockURLProtocol.handler = { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            return (response, responseData)
        }
        defer {
            KycodeMockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        let connectedStore = KycodeConnectionStore(urlSession: session)
        connectedStore.baseURLInput = "https://mock.kycode.test"
        connectedStore.authTokenInput = "test-token"
        await connectedStore.connect()
        XCTAssertTrue(connectedStore.isConnected)

        let cachedData = try XCTUnwrap(UserDefaults.standard.data(forKey: defaultsKey))
        XCTAssertLessThanOrEqual(cachedData.count, 2 * 1_024 * 1_024)
        XCTAssertNil(cachedData.range(of: Data("private/path-that-must-not-be-cached".utf8)))
        XCTAssertNil(cachedData.range(of: Data(String(repeating: "privado", count: 50).utf8)))

        let restoredStore = KycodeConnectionStore(urlSession: session)
        XCTAssertEqual(restoredStore.sessions.map(\.windowId), ["cached-window"])
        XCTAssertEqual(restoredStore.sessions.first?.lastMessagePreview, "Último mensaje visible")
        XCTAssertTrue(restoredStore.isShowingCachedSessions)
        XCTAssertFalse(restoredStore.isConnected)

        connectedStore.disconnect()
        restoredStore.disconnect()
    }

    @MainActor
    private func exerciseRealSendPath(
        expectedMessage: String,
        attachmentCount: Int = 1,
        fastModeEnabled: Bool = false,
        expectedParentNotificationPrompt: String? = nil
    ) async throws -> Int {
        let previousFastModeValue = UserDefaults.standard.object(
            forKey: KycodeFastModePreference.defaultsKey
        ) as? Bool
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KycodeMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        var observedRequests: [URLRequest] = []

        KycodeMockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            if path.hasSuffix("/attachments") {
                return (
                    response,
                    Data(
                        """
                        {"ok":true,"path":"/uploads/capture.png","bytes":9,"mimeType":"image/png"}
                        """.utf8
                    )
                )
            }

            XCTAssertTrue(path.hasSuffix("/message"))
            return (response, Data(#"{"ok":true}"#.utf8))
        }
        defer {
            KycodeMockURLProtocol.handler = nil
            session.invalidateAndCancel()
            if let previousFastModeValue {
                KycodeFastModePreference.save(previousFastModeValue)
            } else {
                UserDefaults.standard.removeObject(forKey: KycodeFastModePreference.defaultsKey)
            }
        }

        let store = KycodeConnectionStore(
            urlSession: session,
            requestObserver: { request in
                observedRequests.append(request)
            },
            initialProfileIdOverride: "puky"
        )
        store.baseURLInput = "https://mock.kycode.test"
        store.authTokenInput = "test-token"
        store.setFastModeEnabled(fastModeEnabled)
        let drafts = (0..<attachmentCount).map { index in
            KycodeImageAttachmentDraft(
                id: "capture-\(index)",
                name: "capture-\(index).png",
                mimeType: "image/png",
                data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01])
            )
        }
        let result = await store.sendMessage(
            windowId: "test-window",
            text: expectedMessage,
            attachments: drafts,
            parentNotificationPrompt: expectedParentNotificationPrompt
        )
        XCTAssertTrue(result.sent, result.errorMessage ?? "El envío falló sin detalle")

        XCTAssertEqual(observedRequests.count, attachmentCount + 1)
        let uploadRequest = try XCTUnwrap(
            observedRequests.first(where: { $0.url?.path.hasSuffix("/attachments") == true })
        )
        XCTAssertEqual(uploadRequest.httpMethod, "POST")
        XCTAssertTrue(
            uploadRequest.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true
        )
        let uploadBody = try XCTUnwrap(uploadRequest.httpBody)
        XCTAssertTrue(uploadBody.range(of: Data("capture-0.png".utf8)) != nil)

        let messageRequest = try XCTUnwrap(
            observedRequests.first(where: { $0.url?.path.hasSuffix("/message") == true })
        )
        XCTAssertEqual(messageRequest.httpMethod, "POST")
        let messageBody = try XCTUnwrap(messageRequest.httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: messageBody) as? [String: Any]
        )
        XCTAssertEqual(object["message"] as? String, expectedMessage)
        let clientMessageId = try XCTUnwrap(object["clientMessageId"] as? String)
        XCTAssertTrue(clientMessageId.hasPrefix("mobile-user-"))
        XCTAssertEqual(object["fastModeEnabled"] as? Bool, fastModeEnabled)
        XCTAssertEqual(
            object["parentNotificationPrompt"] as? String,
            expectedParentNotificationPrompt
        )
        let attachments = try XCTUnwrap(object["attachments"] as? [[String: Any]])
        XCTAssertEqual(attachments.count, attachmentCount)
        XCTAssertEqual(attachments[0]["path"] as? String, "/uploads/capture.png")
        return observedRequests.count
    }
}

final class GoalModeTransportTests: XCTestCase {
    @MainActor
    func testGoalSelectionStaysLocalUntilExplicitSendThenCommitsBeforeOneMessage() async throws {
        let windowId = "goal-\(UUID().uuidString.lowercased())"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KycodeMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        var observedRequests: [URLRequest] = []
        KycodeMockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            if url.path.hasSuffix("/run-mode") {
                return (
                    response,
                    Data(
                        """
                        {"ok":true,"commandId":"cmd-goal","commandState":"accepted","inserted":true,"durable":true,"queuedAt":1,"windowId":"\(windowId)","runMode":"goal","goalStartedAt":2}
                        """.utf8
                    )
                )
            }
            if url.path.hasSuffix("/message") {
                return (
                    response,
                    Data(
                        """
                        {"ok":true,"commandId":"cmd-message","commandState":"accepted","inserted":true,"durable":true,"queuedAt":2}
                        """.utf8
                    )
                )
            }
            let item =
                """
                {"windowId":"\(windowId)","sessionId":"session-1","engine":"codex","projectKey":"project","displayName":"QA","sidecarMode":"remote","activityStatus":"ready","runMode":"goal","goalStartedAt":2,"messageCount":0,"updatedAt":2,"canSend":true}
                """
            if url.path.hasSuffix("/sessions/\(windowId)") {
                return (response, Data(#"{"ok":true,"item":\#(item)}"#.utf8))
            }
            return (response, Data(#"{"ok":true,"items":[\#(item)]}"#.utf8))
        }
        defer {
            KycodeMockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        let store = KycodeConnectionStore(
            urlSession: session,
            requestObserver: { observedRequests.append($0) },
            initialProfileIdOverride: "puky"
        )
        store.baseURLInput = "https://mock.kycode.test"
        store.authTokenInput = "test-token"

        store.stageGoalMode(windowId: windowId, enabled: true)
        XCTAssertTrue(store.displayedGoalModeEnabled(windowId: windowId))
        XCTAssertTrue(store.hasGoalModeDraft(windowId: windowId))
        XCTAssertTrue(observedRequests.isEmpty, "Selecting GOAL must stay local.")

        let result = await store.sendMessage(windowId: windowId, text: "Objetivo explícito")
        XCTAssertTrue(result.sent)
        XCTAssertFalse(store.hasGoalModeDraft(windowId: windowId))
        let commandPaths = observedRequests.compactMap(\.url?.path).compactMap { path in
            if path.hasSuffix("/run-mode") { return "run-mode" }
            if path.hasSuffix("/message") { return "message" }
            return nil
        }
        XCTAssertEqual(commandPaths, ["run-mode", "message"])
    }

    @MainActor
    func testFailedGoalCommitKeepsDraftAndNeverPostsMessage() async throws {
        let windowId = "goal-\(UUID().uuidString.lowercased())"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KycodeMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        var observedRequests: [URLRequest] = []
        KycodeMockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertFalse(url.path.hasSuffix("/message"), "A failed GOAL commit must block send.")
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: url,
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            return (response, Data(#"{"error":"goal unavailable"}"#.utf8))
        }
        defer {
            KycodeMockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        let store = KycodeConnectionStore(
            urlSession: session,
            requestObserver: { observedRequests.append($0) },
            initialProfileIdOverride: "puky"
        )
        store.baseURLInput = "https://mock.kycode.test"
        store.authTokenInput = "test-token"
        store.stageGoalMode(windowId: windowId, enabled: true)

        let result = await store.sendMessage(windowId: windowId, text: "No duplicar")
        XCTAssertFalse(result.sent)
        XCTAssertTrue(store.hasGoalModeDraft(windowId: windowId))
        XCTAssertEqual(
            observedRequests.filter { $0.url?.path.hasSuffix("/run-mode") == true }.count,
            1
        )
        XCTAssertFalse(observedRequests.contains { $0.url?.path.hasSuffix("/message") == true })
    }

    @MainActor
    func testGoalModeUsesRunModeEndpointAndBooleanContract() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KycodeMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        var observedRequests: [URLRequest] = []
        KycodeMockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            if path.hasSuffix("/run-mode") {
                return (
                    response,
                    Data(
                        """
                        {"ok":true,"commandId":"cmd-goal","commandState":"accepted","inserted":true,"durable":true,"queuedAt":1,"windowId":"window/goal","runMode":"goal","goalStartedAt":2}
                        """.utf8
                    )
                )
            }
            let item =
                """
                {"windowId":"window/goal","sessionId":"session-1","engine":"codex","projectKey":"project","displayName":"QA","sidecarMode":"remote","activityStatus":"ready","runMode":"goal","goalStartedAt":2,"messageCount":0,"updatedAt":2,"canSend":true}
                """
            if path.hasSuffix("/sessions/window/goal") {
                return (response, Data(#"{"ok":true,"item":\#(item)}"#.utf8))
            }
            return (response, Data(#"{"ok":true,"items":[\#(item)]}"#.utf8))
        }
        defer {
            KycodeMockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        let store = KycodeConnectionStore(
            urlSession: session,
            requestObserver: { observedRequests.append($0) },
            initialProfileIdOverride: "puky"
        )
        store.baseURLInput = "https://mock.kycode.test"
        store.authTokenInput = "test-token"

        let succeeded = await store.setGoalMode(windowId: "window/goal", enabled: true)
        XCTAssertTrue(succeeded)
        let request = try XCTUnwrap(
            observedRequests.first(where: { $0.url?.path.hasSuffix("/run-mode") == true })
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.percentEncodedPath,
            "/api/mobile/sessions/window%2Fgoal/run-mode"
        )
        let body = try XCTUnwrap(request.httpBody)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Bool])
        XCTAssertEqual(payload["goalEnabled"], true)
    }

    @MainActor
    func testGoalModeOptimisticStateSurvivesStaleSnapshots() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KycodeMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        KycodeMockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            if url.path.hasSuffix("/run-mode") {
                return (
                    response,
                    Data(
                        """
                        {"ok":true,"commandId":"cmd-goal","commandState":"accepted","inserted":true,"durable":true,"queuedAt":1,"windowId":"window/goal","runMode":"goal","goalStartedAt":2}
                        """.utf8
                    )
                )
            }
            let staleItem =
                """
                {"windowId":"window/goal","sessionId":"session-1","engine":"codex","projectKey":"project","displayName":"QA","sidecarMode":"remote","activityStatus":"ready","runMode":"normal","messageCount":0,"updatedAt":1,"canSend":true}
                """
            if url.path.hasSuffix("/sessions/window/goal") {
                return (response, Data(#"{"ok":true,"item":\#(staleItem)}"#.utf8))
            }
            return (response, Data(#"{"ok":true,"items":[\#(staleItem)]}"#.utf8))
        }
        defer {
            KycodeMockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        let store = KycodeConnectionStore(
            urlSession: session,
            initialProfileIdOverride: "puky"
        )
        store.baseURLInput = "https://mock.kycode.test"
        store.authTokenInput = "test-token"
        await store.refreshSessionsNow()
        await store.refreshDetail(windowId: "window/goal")
        XCTAssertFalse(try XCTUnwrap(store.detail(for: "window/goal")).goalModeEnabled)

        let succeeded = await store.setGoalMode(windowId: "window/goal", enabled: true)
        XCTAssertTrue(succeeded)
        XCTAssertTrue(try XCTUnwrap(store.detail(for: "window/goal")).goalModeEnabled)

        await store.refreshSessionsNow()
        await store.refreshDetail(windowId: "window/goal")
        XCTAssertTrue(
            try XCTUnwrap(store.detail(for: "window/goal")).goalModeEnabled,
            "A stale desktop snapshot must not undo the acknowledged optimistic state."
        )
    }

    @MainActor
    func testGoalModeFailureRollsBackToPreviousState() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KycodeMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        KycodeMockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let isRunMode = url.path.hasSuffix("/run-mode")
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: url,
                    statusCode: isRunMode ? 500 : 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            if isRunMode {
                return (response, Data(#"{"error":"rejected"}"#.utf8))
            }
            let item =
                """
                {"windowId":"window/goal","sessionId":"session-1","engine":"codex","projectKey":"project","displayName":"QA","sidecarMode":"remote","activityStatus":"ready","runMode":"normal","messageCount":0,"updatedAt":1,"canSend":true}
                """
            if url.path.hasSuffix("/sessions/window/goal") {
                return (response, Data(#"{"ok":true,"item":\#(item)}"#.utf8))
            }
            return (response, Data(#"{"ok":true,"items":[\#(item)]}"#.utf8))
        }
        defer {
            KycodeMockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        let store = KycodeConnectionStore(
            urlSession: session,
            initialProfileIdOverride: "puky"
        )
        store.baseURLInput = "https://mock.kycode.test"
        store.authTokenInput = "test-token"
        await store.refreshSessionsNow()
        await store.refreshDetail(windowId: "window/goal")

        let succeeded = await store.setGoalMode(windowId: "window/goal", enabled: true)
        XCTAssertFalse(succeeded)
        XCTAssertFalse(try XCTUnwrap(store.detail(for: "window/goal")).goalModeEnabled)
        XCTAssertNotNil(store.errorMessage)
    }

    @MainActor
    func testLatestRapidGoalModeTapWins() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KycodeMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        KycodeMockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            if url.path.hasSuffix("/run-mode") {
                let requestBody = try kycodeRequestBodyData(request)
                let payload = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: requestBody) as? [String: Bool]
                )
                let enabled = try XCTUnwrap(payload["goalEnabled"])
                if enabled {
                    Thread.sleep(forTimeInterval: 0.15)
                }
                let mode = enabled ? "goal" : "normal"
                let startedAt = enabled ? "2" : "null"
                return (
                    response,
                    Data(
                        """
                        {"ok":true,"commandId":"cmd-\(mode)","commandState":"accepted","inserted":true,"durable":true,"queuedAt":1,"windowId":"window/goal","runMode":"\(mode)","goalStartedAt":\(startedAt)}
                        """.utf8
                    )
                )
            }
            let item =
                """
                {"windowId":"window/goal","sessionId":"session-1","engine":"codex","projectKey":"project","displayName":"QA","sidecarMode":"remote","activityStatus":"ready","runMode":"normal","messageCount":0,"updatedAt":1,"canSend":true}
                """
            if url.path.hasSuffix("/sessions/window/goal") {
                return (response, Data(#"{"ok":true,"item":\#(item)}"#.utf8))
            }
            return (response, Data(#"{"ok":true,"items":[\#(item)]}"#.utf8))
        }
        defer {
            KycodeMockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        let store = KycodeConnectionStore(
            urlSession: session,
            initialProfileIdOverride: "puky"
        )
        store.baseURLInput = "https://mock.kycode.test"
        store.authTokenInput = "test-token"
        await store.refreshSessionsNow()
        await store.refreshDetail(windowId: "window/goal")

        let enableTask = Task { await store.setGoalMode(windowId: "window/goal", enabled: true) }
        for _ in 0..<20 where store.detail(for: "window/goal")?.goalModeEnabled != true {
            await Task.yield()
        }
        XCTAssertTrue(try XCTUnwrap(store.detail(for: "window/goal")).goalModeEnabled)

        let disableTask = Task { await store.setGoalMode(windowId: "window/goal", enabled: false) }
        _ = await disableTask.value
        _ = await enableTask.value

        XCTAssertFalse(
            try XCTUnwrap(store.detail(for: "window/goal")).goalModeEnabled,
            "The most recent tap must remain authoritative even if an older request finishes later."
        )
    }
}

final class FeatureMutationQueueTests: XCTestCase {
    @MainActor
    func testQueueAppliesFirstAndLatestIntentWithoutDroppingFinalReversal() async {
        let queue = KycodeLatestIntentMutationQueue<Int>()
        var applied: [Int] = []

        let firstSubmission = Task { @MainActor in
            await queue.submit(1) { value in
                applied.append(value)
                if value == 1 {
                    try? await Task.sleep(for: .milliseconds(120))
                }
                return value != 3
            }
        }

        while applied.isEmpty {
            await Task.yield()
        }

        let middleResult = await queue.submit(2) { _ in
            XCTFail("A queued submitter must not run its own handler.")
            return true
        }
        let finalResult = await queue.submit(3) { value in
            applied.append(value)
            return false
        }

        if case .queued = middleResult {} else {
            XCTFail("The intermediate intent should be queued.")
        }
        if case .queued = finalResult {} else {
            XCTFail("The final intent should replace the intermediate queue entry.")
        }

        let completion = await firstSubmission.value
        XCTAssertEqual(applied, [1, 3])
        if case let .completed(intent, succeeded) = completion {
            XCTAssertEqual(intent, 3)
            XCTAssertFalse(succeeded, "Completion must report the final intent's result.")
        } else {
            XCTFail("The processor submission should own completion.")
        }
    }
}

final class FeatureIntentReconciliationTests: XCTestCase {
    override func tearDown() {
        KycodeMockURLProtocol.handler = nil
        super.tearDown()
    }

    func testProfileHandoffDismissesOnlyAnActuallyPresentedDetail() {
        XCTAssertTrue(
            KycodeDetailNavigationPolicy.shouldDismissPresentedDetail(
                previousProfileId: "personal",
                currentProfileId: "puky",
                hasPresentedDetail: true
            )
        )
        XCTAssertFalse(
            KycodeDetailNavigationPolicy.shouldDismissPresentedDetail(
                previousProfileId: "personal",
                currentProfileId: "personal",
                hasPresentedDetail: true
            )
        )
        XCTAssertFalse(
            KycodeDetailNavigationPolicy.shouldDismissPresentedDetail(
                previousProfileId: "personal",
                currentProfileId: "puky",
                hasPresentedDetail: false
            )
        )
    }

    @MainActor
    func testFeatureIntentRequiresSessionIdentityBeforePostingOrOverlayingReplacement() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KycodeMockURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        var replacementIsAuthoritative = false
        var featurePostCount = 0

        KycodeMockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            if request.httpMethod == "POST", url.path.hasSuffix("/features") {
                featurePostCount += 1
                return (response, Data(#"{"ok":true}"#.utf8))
            }
            if !replacementIsAuthoritative,
               url.path.hasSuffix("/sessions/feature-window") {
                throw URLError(.timedOut)
            }
            let item = self.featureSummary(
                sessionId: "replacement-session",
                promptImproverEnabled: true,
                updatedAt: 2,
                transformStatus: nil
            )
            if url.path.hasSuffix("/sessions/feature-window") {
                return (
                    response,
                    try JSONEncoder().encode(
                        KycodeSessionDetailEnvelope(ok: true, now: item.updatedAt, item: item)
                    )
                )
            }
            return (
                response,
                try JSONEncoder().encode(
                    KycodeSessionsEnvelope(ok: true, now: item.updatedAt, exportedAt: nil, items: [item])
                )
            )
        }
        defer { urlSession.invalidateAndCancel() }

        let store = KycodeConnectionStore(
            urlSession: urlSession,
            initialProfileIdOverride: "puky"
        )
        store.baseURLInput = "https://mock.kycode.test"
        store.authTokenInput = "test-token"

        let succeeded = await store.setFeatures(
            windowId: "feature-window",
            promptImproverEnabled: false,
            explainerEnabled: false
        )
        XCTAssertFalse(succeeded)
        XCTAssertEqual(featurePostCount, 0)
        XCTAssertNotNil(store.errorMessage)

        replacementIsAuthoritative = true
        await store.refreshSessionsNow()
        await store.refreshDetail(windowId: "feature-window")
        XCTAssertEqual(store.detail(for: "feature-window")?.sessionId, "replacement-session")
        XCTAssertEqual(store.detail(for: "feature-window")?.features?.promptImproverEnabled, true)
        XCTAssertEqual(featurePostCount, 0)
        store.disconnect()
    }

    @MainActor
    func testFeatureIntentExpiresWithInjectedMonotonicClockAndReturnsToAuthority() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KycodeMockURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        var monotonicNow: TimeInterval = 0
        var featurePostCount = 0
        var messagePostCount = 0

        KycodeMockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            if request.httpMethod == "POST", url.path.hasSuffix("/features") {
                featurePostCount += 1
                return (response, Data(#"{"ok":true}"#.utf8))
            }
            if request.httpMethod == "POST", url.path.hasSuffix("/message") {
                messagePostCount += 1
            }
            let item = self.featureSummary(
                promptImproverEnabled: true,
                updatedAt: 2,
                transformStatus: "processing"
            )
            if url.path.hasSuffix("/sessions/feature-window") {
                return (
                    response,
                    try JSONEncoder().encode(
                        KycodeSessionDetailEnvelope(ok: true, now: item.updatedAt, item: item)
                    )
                )
            }
            return (
                response,
                try JSONEncoder().encode(
                    KycodeSessionsEnvelope(ok: true, now: item.updatedAt, exportedAt: nil, items: [item])
                )
            )
        }
        defer { urlSession.invalidateAndCancel() }

        let store = KycodeConnectionStore(
            urlSession: urlSession,
            initialProfileIdOverride: "puky",
            featureReconciliationNow: { monotonicNow },
            featureReconciliationSleep: { _ in
                monotonicNow = 30
                await Task.yield()
            }
        )
        store.baseURLInput = "https://mock.kycode.test"
        store.authTokenInput = "test-token"
        await store.refreshSessionsNow()
        await store.refreshDetail(windowId: "feature-window")

        let succeeded = await store.setFeatures(
            windowId: "feature-window",
            promptImproverEnabled: false,
            explainerEnabled: false
        )
        XCTAssertTrue(succeeded)
        for _ in 0..<40 where
            store.detail(for: "feature-window")?.features?.promptImproverEnabled != true {
            await Task.yield()
        }

        XCTAssertEqual(store.detail(for: "feature-window")?.features?.promptImproverEnabled, true)
        XCTAssertEqual(
            store.detail(for: "feature-window")?.messages?.first?.transformStatus,
            "processing"
        )
        XCTAssertEqual(featurePostCount, 1)
        XCTAssertEqual(messagePostCount, 0)
        store.disconnect()
    }

    @MainActor
    func testFeatureIntentSurvivesStaleDetailSessionsAndUpsertUntilBothSourcesConfirm() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KycodeMockURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        var serverPromptImproverEnabled = true
        var serverRevision: Double = 1
        var featurePostCount = 0
        var messagePostCount = 0

        KycodeMockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            if request.httpMethod == "POST", url.path.hasSuffix("/features") {
                featurePostCount += 1
                return (
                    response,
                    Data(
                        #"{"ok":true,"commandId":"feature-intent-1","commandState":"accepted","inserted":true,"durable":true,"queuedAt":1}"#.utf8
                    )
                )
            }
            if request.httpMethod == "POST", url.path.hasSuffix("/message") {
                messagePostCount += 1
            }
            let item = self.featureSummary(
                promptImproverEnabled: serverPromptImproverEnabled,
                updatedAt: serverRevision,
                transformStatus: "processing"
            )
            if url.path.hasSuffix("/sessions/feature-window") {
                return (
                    response,
                    try JSONEncoder().encode(
                        KycodeSessionDetailEnvelope(ok: true, now: serverRevision, item: item)
                    )
                )
            }
            return (
                response,
                try JSONEncoder().encode(
                    KycodeSessionsEnvelope(
                        ok: true,
                        now: serverRevision,
                        exportedAt: nil,
                        items: [item]
                    )
                )
            )
        }
        defer {
            urlSession.invalidateAndCancel()
        }

        let store = KycodeConnectionStore(
            urlSession: urlSession,
            initialProfileIdOverride: "puky"
        )
        store.baseURLInput = "https://mock.kycode.test"
        store.authTokenInput = "test-token"
        await store.refreshSessionsNow()
        await waitForFeatureDetail(in: store)

        let succeeded = await store.setFeatures(
            windowId: "feature-window",
            promptImproverEnabled: false,
            explainerEnabled: false
        )
        XCTAssertTrue(succeeded)
        XCTAssertEqual(store.detail(for: "feature-window")?.features?.promptImproverEnabled, false)

        store.applyStreamSessionUpsert(
            featureSummary(
                promptImproverEnabled: true,
                updatedAt: 2,
                transformStatus: "processing"
            )
        )
        XCTAssertEqual(
            store.detail(for: "feature-window")?.features?.promptImproverEnabled,
            false,
            "A stale upsert must not bounce an acknowledged toggle."
        )
        XCTAssertEqual(
            store.detail(for: "feature-window")?.messages?.first?.transformStatus,
            "processing",
            "Changing the preference must not interrupt a prompt already being improved."
        )

        try await Task.sleep(for: .milliseconds(1_100))
        serverPromptImproverEnabled = false
        serverRevision = 3
        await store.refreshSessionsNow()
        await store.refreshDetail(windowId: "feature-window")
        try await Task.sleep(for: .milliseconds(50))
        await store.refreshDetail(windowId: "feature-window")
        XCTAssertEqual(store.detail(for: "feature-window")?.features?.promptImproverEnabled, false)

        serverPromptImproverEnabled = true
        serverRevision = 4
        await store.refreshSessionsNow()
        await store.refreshDetail(windowId: "feature-window")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(
            store.detail(for: "feature-window")?.features?.promptImproverEnabled,
            true,
            "After both authoritative sources confirm, later authority must be able to change normally."
        )
        XCTAssertEqual(featurePostCount, 1)
        XCTAssertEqual(messagePostCount, 0)
        store.disconnect()
    }

    @MainActor
    func testTerminalFeatureFailureRollsBackOnlyFeaturesAndPreservesPromptLifecycle() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KycodeMockURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        let baseline = featureSummary(
            promptImproverEnabled: true,
            updatedAt: 1,
            transformStatus: "processing"
        )

        KycodeMockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            if request.httpMethod == "POST", url.path.hasSuffix("/features") {
                return (
                    response,
                    Data(
                        #"{"ok":true,"commandId":"feature-failure-1","commandState":"accepted","inserted":true,"durable":true,"queuedAt":1}"#.utf8
                    )
                )
            }
            if url.path.hasSuffix("/sessions/feature-window") {
                return (
                    response,
                    try JSONEncoder().encode(
                        KycodeSessionDetailEnvelope(ok: true, now: 1, item: baseline)
                    )
                )
            }
            return (
                response,
                try JSONEncoder().encode(
                    KycodeSessionsEnvelope(ok: true, now: 1, exportedAt: nil, items: [baseline])
                )
            )
        }
        defer {
            urlSession.invalidateAndCancel()
        }

        let store = KycodeConnectionStore(
            urlSession: urlSession,
            initialProfileIdOverride: "puky"
        )
        store.baseURLInput = "https://mock.kycode.test"
        store.authTokenInput = "test-token"
        await store.refreshSessionsNow()
        await waitForFeatureDetail(in: store)

        let succeeded = await store.setFeatures(
            windowId: "feature-window",
            promptImproverEnabled: false,
            explainerEnabled: false
        )
        XCTAssertTrue(succeeded)
        XCTAssertEqual(store.detail(for: "feature-window")?.features?.promptImproverEnabled, false)

        store.applyDurableCommandStateChanged(
            KycodeCommandStateChangedEvent(
                commandId: "feature-failure-1",
                state: .failed,
                error: "feature rejected"
            )
        )

        let rolledBack = try XCTUnwrap(store.detail(for: "feature-window"))
        XCTAssertEqual(rolledBack.features?.promptImproverEnabled, true)
        XCTAssertEqual(rolledBack.messages?.first?.id, "prompt-in-flight")
        XCTAssertEqual(rolledBack.messages?.first?.transformStatus, "processing")
        XCTAssertTrue(store.errorMessage?.contains("feature rejected") == true)
        store.disconnect()
    }

    @MainActor
    func testLateSessionsRefreshCannotRepopulateStoreAfterGenerationReset() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KycodeMockURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        let requestStarted = expectation(description: "sessions request started")
        let releaseResponse = DispatchSemaphore(value: 0)
        let item = featureSummary(
            promptImproverEnabled: true,
            updatedAt: 1,
            transformStatus: nil
        )

        KycodeMockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            requestStarted.fulfill()
            _ = releaseResponse.wait(timeout: .now() + 3)
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            return (
                response,
                try JSONEncoder().encode(
                    KycodeSessionsEnvelope(ok: true, now: 1, exportedAt: nil, items: [item])
                )
            )
        }
        defer {
            releaseResponse.signal()
            urlSession.invalidateAndCancel()
        }

        let store = KycodeConnectionStore(
            urlSession: urlSession,
            initialProfileIdOverride: "puky"
        )
        store.baseURLInput = "https://mock.kycode.test"
        store.authTokenInput = "test-token"

        let refreshTask = Task { await store.refreshSessionsNow() }
        await fulfillment(of: [requestStarted], timeout: 1)
        store.disconnect()
        releaseResponse.signal()
        await refreshTask.value

        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertTrue(store.sessionDetails.isEmpty)
        XCTAssertNil(store.errorMessage)
    }

    @MainActor
    private func waitForFeatureDetail(in store: KycodeConnectionStore) async {
        for _ in 0..<100 where store.sessionDetails["feature-window"] == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func featureSummary(
        sessionId: String = "feature-session",
        promptImproverEnabled: Bool,
        updatedAt: Double,
        transformStatus: String?
    ) -> KycodeSessionSummary {
        let messages: [KycodeMessage]? = transformStatus.map { status in
            [
                KycodeMessage(
                    id: "prompt-in-flight",
                    role: "user",
                    type: "user",
                    content: "Prompt en curso",
                    originalPrompt: "Prompt en curso",
                    transformedPrompt: nil,
                    improvedPrompt: nil,
                    timestamp: 1,
                    status: nil,
                    imageAttachments: nil,
                    transformStatus: status,
                    transformErrorReason: nil,
                    promptTransformNote: nil
                )
            ]
        }
        return KycodeSessionSummary(
            windowId: "feature-window",
            sessionId: sessionId,
            engine: "codex",
            model: "gpt-5.6-luna",
            reasoningEffort: "low",
            providerSessionId: nil,
            providerSessionPath: nil,
            projectKey: "fermin-code-mobile",
            projectPath: "/tmp/fermin-code-mobile",
            projectName: "Fermín Code Mobile",
            windowName: "Feature intent QA",
            displayName: "Feature intent QA",
            sidecarMode: "mobile",
            sidecarUrl: nil,
            activityStatus: transformStatus == nil ? "ready" : "working",
            runtimeStatus: transformStatus == nil ? "READY" : "WORKING",
            runtimeStatusDetail: nil,
            features: KycodeSessionFeatures(
                promptImproverEnabled: promptImproverEnabled,
                explainerEnabled: false,
                codeContextEnabled: true
            ),
            messageCount: messages?.count ?? 0,
            updatedAt: updatedAt,
            createdAt: 1,
            rawPrompt: nil,
            originalPrompt: nil,
            improvedPrompt: nil,
            lastMessagePreview: messages?.first?.content,
            isMinimized: false,
            canSend: true,
            canControlFeatures: true,
            unsupportedReason: nil,
            messages: messages
        )
    }

}

final class RuntimeModelSettingsTransportTests: XCTestCase {
    override func tearDown() {
        KycodeMockURLProtocol.handler = nil
        super.tearDown()
    }

    func testCompactSwitcherLabelsCoverOfficialGPT56FamilyAndEfforts() {
        XCTAssertEqual(
            RuntimeModelSwitcherPresentation.compactModelLabel("gpt-5.6-sol"),
            "SOL"
        )
        XCTAssertEqual(
            RuntimeModelSwitcherPresentation.compactModelLabel("gpt-5.6-terra"),
            "TERRA"
        )
        XCTAssertEqual(
            RuntimeModelSwitcherPresentation.compactModelLabel("gpt-5.6-luna"),
            "LUNA"
        )
        XCTAssertEqual(
            RuntimeModelSwitcherPresentation.compactEffortLabel("xhigh"),
            "XHIGH"
        )
        XCTAssertEqual(
            RuntimeModelSwitcherPresentation.compactEffortLabel("max"),
            "MAX"
        )
        XCTAssertEqual(
            RuntimeModelSwitcherPresentation.accessibilityValue(
                model: "gpt-5.6-luna",
                effort: "low"
            ),
            "LUNA, LOW"
        )
    }

    @MainActor
    func testCatalogUsesLiveSessionEndpointAndDecodesEfforts() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KycodeMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var observedRequests: [URLRequest] = []

        KycodeMockURLProtocol.handler = { request in
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
                Data(
                    """
                    {
                      "ok":true,
                      "data":[{
                        "id":"gpt-5.6-sol",
                        "model":"gpt-5.6-sol",
                        "displayName":"GPT-5.6-SOL",
                        "defaultReasoningEffort":"high",
                        "supportedReasoningEfforts":[
                          {"reasoningEffort":"medium","description":"Equilibrado"},
                          {"reasoningEffort":"xhigh","description":"Máximo"}
                        ],
                        "hidden":false,
                        "isDefault":true
                      },{
                        "id":"grok-4",
                        "model":"grok-4",
                        "displayName":"Grok 4",
                        "defaultReasoningEffort":"high",
                        "supportedReasoningEfforts":[
                          {"reasoningEffort":"high","description":"Profundo"}
                        ],
                        "hidden":false,
                        "isDefault":false
                      },{
                        "id":"claude-opus",
                        "model":"claude-opus-4-6",
                        "displayName":"Claude Opus",
                        "defaultReasoningEffort":"high",
                        "supportedReasoningEfforts":[
                          {"reasoningEffort":"high","description":"Profundo"}
                        ],
                        "hidden":false,
                        "isDefault":false
                      }]
                    }
                    """.utf8
                )
            )
        }

        let store = KycodeConnectionStore(
            urlSession: session,
            requestObserver: { observedRequests.append($0) }
        )
        store.baseURLInput = "https://mock.kycode.test"
        store.authTokenInput = "test-token"

        let models = try await store.modelCatalog(windowId: "window/catalog")
        XCTAssertEqual(models.map(\.model), ["gpt-5.6-sol"])
        XCTAssertEqual(models[0].supportedReasoningEfforts.map(\.reasoningEffort), ["medium", "xhigh"])
        let request = try XCTUnwrap(observedRequests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.timeoutInterval, 115, accuracy: 0.001)
        XCTAssertEqual(
            request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.percentEncodedPath,
            "/api/mobile/sessions/window%2Fcatalog/models"
        )
    }

    @MainActor
    func testFeatureToggleUsesBoundedAckTimeoutAndNativePayload() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KycodeMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var observedRequests: [URLRequest] = []

        KycodeMockURLProtocol.handler = { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            let path = request.url?.path ?? ""
            if request.httpMethod == "POST", path.hasSuffix("/features") {
                return (response, Data(#"{"ok":true}"#.utf8))
            }
            let item =
                """
                {"windowId":"window/features","sessionId":"session-features","engine":"codex","model":"gpt-5.6-sol","reasoningEffort":"high","projectKey":"project","displayName":"Features QA","sidecarMode":"remote","activityStatus":"ready","features":{"promptImproverEnabled":true,"explainerEnabled":false,"codeContextEnabled":false},"messageCount":0,"updatedAt":2,"canSend":true,"canControlFeatures":true}
                """
            if path.contains("/sessions/window") {
                return (response, Data(#"{"ok":true,"item":\#(item)}"#.utf8))
            }
            return (response, Data(#"{"ok":true,"now":2,"items":[\#(item)]}"#.utf8))
        }

        let store = KycodeConnectionStore(
            urlSession: session,
            requestObserver: { observedRequests.append($0) }
        )
        store.baseURLInput = "https://mock.kycode.test"
        store.authTokenInput = "test-token"

        let succeeded = await store.setFeatures(
            windowId: "window/features",
            promptImproverEnabled: true,
            explainerEnabled: false
        )
        XCTAssertTrue(succeeded)

        let request = try XCTUnwrap(
            observedRequests.first {
                $0.httpMethod == "POST" && $0.url?.path.hasSuffix("/features") == true
            }
        )
        XCTAssertEqual(request.timeoutInterval, 5, accuracy: 0.001)
        let body = try XCTUnwrap(request.httpBody)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Bool])
        XCTAssertEqual(payload["promptImproverEnabled"], true)
        XCTAssertEqual(payload["explainerEnabled"], false)
        XCTAssertNil(payload["codeContextEnabled"])
        XCTAssertEqual(store.detail(for: "window/features")?.features?.promptImproverEnabled, true)
    }

    @MainActor
    func testModelChangeSendsNativeSettingsContractAndReconcilesServerValue() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KycodeMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var observedRequests: [URLRequest] = []

        KycodeMockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            if path.hasSuffix("/model-settings") {
                return (
                    response,
                    Data(
                        """
                        {"ok":true,"modelSettings":{"model":"gpt-5.6-sol","effort":"xhigh"},"command":{"ok":true,"commandId":"cmd-model","commandState":"accepted","inserted":true,"durable":true,"queuedAt":1}}
                        """.utf8
                    )
                )
            }
            let item =
                """
                {"windowId":"window/settings","sessionId":"session-1","engine":"codex","model":"gpt-5.6-sol","reasoningEffort":"xhigh","projectKey":"project","displayName":"QA","sidecarMode":"remote","activityStatus":"ready","messageCount":0,"updatedAt":2,"canSend":true,"canControlFeatures":true}
                """
            if path.hasSuffix("/sessions/window/settings") {
                return (response, Data(#"{"ok":true,"item":\#(item)}"#.utf8))
            }
            return (response, Data(#"{"ok":true,"now":2,"items":[\#(item)]}"#.utf8))
        }

        let store = KycodeConnectionStore(
            urlSession: session,
            requestObserver: { observedRequests.append($0) }
        )
        store.baseURLInput = "https://mock.kycode.test"
        store.authTokenInput = "test-token"

        let succeeded = await store.setRuntimeModelSettings(
            windowId: "window/settings",
            model: "gpt-5.6-sol",
            reasoningEffort: "XHIGH"
        )
        XCTAssertTrue(succeeded)
        let request = try XCTUnwrap(
            observedRequests.first(where: { $0.url?.path.hasSuffix("/model-settings") == true })
        )
        let body = try XCTUnwrap(request.httpBody)
        XCTAssertEqual(request.timeoutInterval, 115, accuracy: 0.001)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(payload["model"], "gpt-5.6-sol")
        XCTAssertEqual(payload["reasoningEffort"], "xhigh")
        XCTAssertEqual(store.detail(for: "window/settings")?.reasoningEffort, "xhigh")
    }

    @MainActor
    func testRejectedModelChangeReturnsFailureWithoutLeavingOptimisticErrorState() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KycodeMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        KycodeMockURLProtocol.handler = { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 409,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            return (response, Data(#"{"error":"unsupported reasoning effort"}"#.utf8))
        }

        let store = KycodeConnectionStore(urlSession: session)
        store.baseURLInput = "https://mock.kycode.test"
        store.authTokenInput = "test-token"
        let succeeded = await store.setRuntimeModelSettings(
            windowId: "window/rejected",
            model: "gpt-5.6-sol",
            reasoningEffort: "xhigh"
        )
        XCTAssertFalse(succeeded)
        XCTAssertNil(store.detail(for: "window/rejected"))
        XCTAssertNotNil(store.errorMessage)
    }

    @MainActor
    func testNonGPTModelChangeIsRejectedBeforeAnyNetworkRequest() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KycodeMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var observedRequests: [URLRequest] = []

        let store = KycodeConnectionStore(
            urlSession: session,
            requestObserver: { observedRequests.append($0) }
        )
        let succeeded = await store.setRuntimeModelSettings(
            windowId: "window/rejected-grok",
            model: "grok-4",
            reasoningEffort: "high"
        )

        XCTAssertFalse(succeeded)
        XCTAssertTrue(observedRequests.isEmpty)
        XCTAssertEqual(store.errorMessage, "Fermín Code sólo admite modelos GPT.")
    }

    @MainActor
    func testDurableModelSelectionSurvivesStaleUpsertDetailPromptRetryCompletionAndRelaunch() async throws {
        let suiteName = "RuntimeModelSettingsTransportTests.sticky.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KycodeMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            KycodeMockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }
        var authorityUsesSolMax = false
        var detailCarriesImprovedPrompt = false

        func itemJSON() -> String {
            let model = authorityUsesSolMax ? "gpt-5.6-sol" : "gpt-5.6-luna"
            let effort = authorityUsesSolMax ? "max" : "high"
            let improvedPrompt = detailCarriesImprovedPrompt
                ? ",\"improvedPrompt\":\"Prompt mejorado por Fermín\""
                : ""
            return """
            {"windowId":"runtime-sticky-window","sessionId":"runtime-sticky-session","engine":"codex","model":"\(model)","reasoningEffort":"\(effort)","projectKey":"project","displayName":"Sticky QA","sidecarMode":"remote","activityStatus":"ready","messageCount":1,"updatedAt":2,"canSend":true,"canControlFeatures":true\(improvedPrompt)}
            """
        }

        KycodeMockURLProtocol.handler = { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            let path = request.url?.path ?? ""
            if path.hasSuffix("/model-settings") {
                return (
                    response,
                    Data(
                        #"{"ok":true,"modelSettings":{"model":"gpt-5.6-sol","effort":"max"},"command":{"ok":true,"commandId":"cmd-runtime-sticky","commandState":"accepted","inserted":true,"durable":true,"queuedAt":1}}"#.utf8
                    )
                )
            }
            if path.hasSuffix("/retry-prompt-transform") {
                detailCarriesImprovedPrompt = true
                return (
                    response,
                    Data(
                        #"{"ok":true,"commandId":"cmd-prompt-sticky","commandState":"accepted","inserted":true,"durable":true,"queuedAt":2,"messageId":"message-1"}"#.utf8
                    )
                )
            }
            if path.hasSuffix("/runtime-sticky-window") {
                return (response, Data("{\"ok\":true,\"item\":\(itemJSON())}".utf8))
            }
            return (response, Data("{\"ok\":true,\"now\":2,\"items\":[\(itemJSON())]}".utf8))
        }

        func makeStore() -> KycodeConnectionStore {
            let store = KycodeConnectionStore(
                urlSession: session,
                initialProfileIdOverride: "personal",
                messageReconciliationSleep: { _ in await Task.yield() },
                runtimeSettingsDefaults: defaults
            )
            store.baseURLInput = "https://relay.example.com/fermin-code"
            store.authTokenInput = "test-token"
            return store
        }

        var store: KycodeConnectionStore? = makeStore()
        await store?.refreshSessionsNow()
        await store?.refreshDetail(windowId: "runtime-sticky-window")
        XCTAssertEqual(store?.detail(for: "runtime-sticky-window")?.model, "gpt-5.6-luna")
        XCTAssertEqual(store?.detail(for: "runtime-sticky-window")?.reasoningEffort, "high")

        let succeeded = await store?.setRuntimeModelSettings(
            windowId: "runtime-sticky-window",
            model: "gpt-5.6-sol",
            reasoningEffort: "max"
        )
        XCTAssertEqual(succeeded, true)
        XCTAssertEqual(store?.detail(for: "runtime-sticky-window")?.model, "gpt-5.6-sol")
        XCTAssertEqual(store?.detail(for: "runtime-sticky-window")?.reasoningEffort, "max")

        let staleUpsert = try JSONDecoder().decode(
            KycodeSessionSummary.self,
            from: Data(itemJSON().utf8)
        )
        store?.applyStreamSessionUpsert(staleUpsert)
        XCTAssertEqual(store?.sessions.first?.model, "gpt-5.6-sol")
        XCTAssertEqual(store?.sessions.first?.reasoningEffort, "max")

        let retryResult = await store?.retryPromptImprover(
            windowId: "runtime-sticky-window",
            messageId: "message-1"
        )
        XCTAssertEqual(retryResult, .success)
        XCTAssertEqual(store?.detail(for: "runtime-sticky-window")?.improvedPrompt, "Prompt mejorado por Fermín")
        XCTAssertEqual(store?.detail(for: "runtime-sticky-window")?.model, "gpt-5.6-sol")
        XCTAssertEqual(store?.detail(for: "runtime-sticky-window")?.reasoningEffort, "max")

        store?.applyDurableCommandStateChanged(
            KycodeCommandStateChangedEvent(
                commandId: "cmd-runtime-sticky",
                state: .completed,
                error: nil
            )
        )
        await store?.refreshDetail(windowId: "runtime-sticky-window")
        XCTAssertEqual(store?.detail(for: "runtime-sticky-window")?.model, "gpt-5.6-sol")
        XCTAssertEqual(store?.detail(for: "runtime-sticky-window")?.reasoningEffort, "max")

        store?.disconnect()
        store = nil

        let relaunchedStore = makeStore()
        await relaunchedStore.refreshSessionsNow()
        await relaunchedStore.refreshDetail(windowId: "runtime-sticky-window")
        XCTAssertEqual(relaunchedStore.detail(for: "runtime-sticky-window")?.model, "gpt-5.6-sol")
        XCTAssertEqual(relaunchedStore.detail(for: "runtime-sticky-window")?.reasoningEffort, "max")

        authorityUsesSolMax = true
        await relaunchedStore.refreshSessionsNow()
        await relaunchedStore.refreshDetail(windowId: "runtime-sticky-window")
        XCTAssertEqual(relaunchedStore.detail(for: "runtime-sticky-window")?.model, "gpt-5.6-sol")
        XCTAssertEqual(relaunchedStore.detail(for: "runtime-sticky-window")?.reasoningEffort, "max")
        XCTAssertNil(defaults.data(forKey: "kycode.mobile.pendingRuntimeSettings.v1"))
        relaunchedStore.disconnect()
    }

    @MainActor
    func testDurableModelSelectionRollsBackOnlyOnTerminalFailure() async throws {
        let suiteName = "RuntimeModelSettingsTransportTests.rollback.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KycodeMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            KycodeMockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }
        let item = #"{"windowId":"runtime-failure-window","sessionId":"runtime-failure-session","engine":"codex","model":"gpt-5.6-luna","reasoningEffort":"high","projectKey":"project","displayName":"Failure QA","sidecarMode":"remote","activityStatus":"ready","messageCount":0,"updatedAt":2,"canSend":true,"canControlFeatures":true}"#
        KycodeMockURLProtocol.handler = { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            if request.url?.path.hasSuffix("/model-settings") == true {
                return (
                    response,
                    Data(
                        #"{"ok":true,"modelSettings":{"model":"gpt-5.6-sol","effort":"max"},"command":{"ok":true,"commandId":"cmd-runtime-failure","commandState":"accepted","inserted":true,"durable":true,"queuedAt":1}}"#.utf8
                    )
                )
            }
            if request.url?.path.hasSuffix("/runtime-failure-window") == true {
                return (response, Data("{\"ok\":true,\"item\":\(item)}".utf8))
            }
            return (response, Data("{\"ok\":true,\"now\":2,\"items\":[\(item)]}".utf8))
        }

        let store = KycodeConnectionStore(
            urlSession: session,
            initialProfileIdOverride: "personal",
            runtimeSettingsDefaults: defaults
        )
        store.baseURLInput = "https://relay.example.com/fermin-code"
        store.authTokenInput = "test-token"
        await store.refreshSessionsNow()
        await store.refreshDetail(windowId: "runtime-failure-window")
        let succeeded = await store.setRuntimeModelSettings(
            windowId: "runtime-failure-window",
            model: "gpt-5.6-sol",
            reasoningEffort: "max"
        )
        XCTAssertTrue(succeeded)
        XCTAssertEqual(store.detail(for: "runtime-failure-window")?.model, "gpt-5.6-sol")

        store.applyDurableCommandStateChanged(
            KycodeCommandStateChangedEvent(
                commandId: "cmd-runtime-failure",
                state: .failed,
                error: "runtime rejected settings"
            )
        )

        XCTAssertEqual(store.detail(for: "runtime-failure-window")?.model, "gpt-5.6-luna")
        XCTAssertEqual(store.detail(for: "runtime-failure-window")?.reasoningEffort, "high")
        XCTAssertNotNil(store.errorMessage)
        XCTAssertNil(defaults.data(forKey: "kycode.mobile.pendingRuntimeSettings.v1"))
        store.disconnect()
    }
}

final class ConnectionTargetSelectionTests: XCTestCase {
    private let profilesKey = "kycode.mobile.connectionProfiles"
    private let selectedProfileKey = "kycode.mobile.selectedProfileId"
    private let credentialMigrationVersionKey = "kycode.mobile.connectionCredentialMigrationVersion"
    private let cachedSessionsKey = "kycode.mobile.cachedSessions.v1"
    private let sessionDisplayOrdersKey = "kycode.mobile.sessionDisplayOrders.v1"
    private var previousProfiles: Data?
    private var previousSelectedProfile: String?
    private var previousCredentialMigrationVersion: Any?
    private var previousCachedSessions: Any?
    private var previousSessionDisplayOrders: Any?
    private var previousPromptImproverLegacy: Any?
    private var previousPromptImproverPersonal: Any?
    private var previousPromptImproverPuky: Any?
    private var previousPukyToken: String?
    private var previousPersonalToken: String?

    override func setUp() {
        super.setUp()
        previousProfiles = UserDefaults.standard.data(forKey: profilesKey)
        previousSelectedProfile = UserDefaults.standard.string(forKey: selectedProfileKey)
        previousCredentialMigrationVersion = UserDefaults.standard.object(forKey: credentialMigrationVersionKey)
        previousCachedSessions = UserDefaults.standard.object(forKey: cachedSessionsKey)
        previousSessionDisplayOrders = UserDefaults.standard.object(forKey: sessionDisplayOrdersKey)
        previousPromptImproverLegacy = UserDefaults.standard.object(
            forKey: KycodePromptImproverPreferenceStore.defaultsKey
        )
        previousPromptImproverPersonal = UserDefaults.standard.object(
            forKey: KycodePromptImproverPreferenceStore.storageKey(profileId: "personal")
        )
        previousPromptImproverPuky = UserDefaults.standard.object(
            forKey: KycodePromptImproverPreferenceStore.storageKey(profileId: "puky")
        )
        previousPukyToken = KycodeKeychain.loadAuthToken(profileId: "puky")
        previousPersonalToken = KycodeKeychain.loadAuthToken(profileId: "personal")
        UserDefaults.standard.removeObject(forKey: cachedSessionsKey)
        UserDefaults.standard.removeObject(forKey: sessionDisplayOrdersKey)
        UserDefaults.standard.removeObject(forKey: KycodePromptImproverPreferenceStore.defaultsKey)
        UserDefaults.standard.removeObject(
            forKey: KycodePromptImproverPreferenceStore.storageKey(profileId: "personal")
        )
        UserDefaults.standard.removeObject(
            forKey: KycodePromptImproverPreferenceStore.storageKey(profileId: "puky")
        )
        UserDefaults.standard.set(3, forKey: credentialMigrationVersionKey)
    }

    override func tearDown() {
        if let previousProfiles {
            UserDefaults.standard.set(previousProfiles, forKey: profilesKey)
        } else {
            UserDefaults.standard.removeObject(forKey: profilesKey)
        }
        if let previousSelectedProfile {
            UserDefaults.standard.set(previousSelectedProfile, forKey: selectedProfileKey)
        } else {
            UserDefaults.standard.removeObject(forKey: selectedProfileKey)
        }
        if let previousCredentialMigrationVersion {
            UserDefaults.standard.set(previousCredentialMigrationVersion, forKey: credentialMigrationVersionKey)
        } else {
            UserDefaults.standard.removeObject(forKey: credentialMigrationVersionKey)
        }
        if let previousCachedSessions {
            UserDefaults.standard.set(previousCachedSessions, forKey: cachedSessionsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: cachedSessionsKey)
        }
        if let previousSessionDisplayOrders {
            UserDefaults.standard.set(previousSessionDisplayOrders, forKey: sessionDisplayOrdersKey)
        } else {
            UserDefaults.standard.removeObject(forKey: sessionDisplayOrdersKey)
        }
        if let previousPromptImproverLegacy {
            UserDefaults.standard.set(
                previousPromptImproverLegacy,
                forKey: KycodePromptImproverPreferenceStore.defaultsKey
            )
        } else {
            UserDefaults.standard.removeObject(forKey: KycodePromptImproverPreferenceStore.defaultsKey)
        }
        if let previousPromptImproverPersonal {
            UserDefaults.standard.set(
                previousPromptImproverPersonal,
                forKey: KycodePromptImproverPreferenceStore.storageKey(profileId: "personal")
            )
        } else {
            UserDefaults.standard.removeObject(
                forKey: KycodePromptImproverPreferenceStore.storageKey(profileId: "personal")
            )
        }
        if let previousPromptImproverPuky {
            UserDefaults.standard.set(
                previousPromptImproverPuky,
                forKey: KycodePromptImproverPreferenceStore.storageKey(profileId: "puky")
            )
        } else {
            UserDefaults.standard.removeObject(
                forKey: KycodePromptImproverPreferenceStore.storageKey(profileId: "puky")
            )
        }
        if let previousPukyToken {
            KycodeKeychain.saveAuthToken(previousPukyToken, profileId: "puky")
        } else {
            KycodeKeychain.deleteAuthToken(profileId: "puky")
        }
        if let previousPersonalToken {
            KycodeKeychain.saveAuthToken(previousPersonalToken, profileId: "personal")
        } else {
            KycodeKeychain.deleteAuthToken(profileId: "personal")
        }
        KycodeMockURLProtocol.handler = nil
        super.tearDown()
    }

    func testComposerDraftStorageSeparatesProfilesAndRequiresExplicitLegacyRecovery() throws {
        let suiteName = "KycodeComposerDraftStoragePolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let windowId = "shared-window"
        let personalKey = KycodeComposerDraftStoragePolicy.storageKey(
            profileId: "personal",
            remoteWindowId: windowId
        )
        let pukyKey = KycodeComposerDraftStoragePolicy.storageKey(
            profileId: "puky",
            remoteWindowId: windowId
        )
        XCTAssertNotEqual(personalKey, pukyKey)

        let legacyKey = KycodeComposerDraftStoragePolicy.legacyStorageKey(windowId: windowId)
        defaults.set("Borrador Personal", forKey: legacyKey)
        XCTAssertNil(
            KycodeComposerDraftStoragePolicy.loadDraft(
                defaults: defaults,
                storageKey: personalKey
            )
        )
        XCTAssertEqual(
            KycodeComposerDraftStoragePolicy.legacyDraft(
                defaults: defaults,
                windowId: windowId
            ),
            "Borrador Personal"
        )
        XCTAssertEqual(
            KycodeComposerDraftStoragePolicy.recoverLegacyDraft(
                defaults: defaults,
                storageKey: personalKey,
                legacyWindowId: windowId
            ),
            "Borrador Personal"
        )
        XCTAssertNil(defaults.string(forKey: legacyKey))

        defaults.set("Borrador Puky", forKey: pukyKey)
        XCTAssertEqual(defaults.string(forKey: personalKey), "Borrador Personal")
        XCTAssertEqual(defaults.string(forKey: pukyKey), "Borrador Puky")
    }

    @MainActor
    func testLegacyProfilesMigrateToBothRemoteOnlyRustTargets() throws {
        let legacyProfiles = [
            KycodeConnectionProfile(
                id: "this-mac",
                name: "Esta Mac",
                mode: .bonjourOnly,
                remoteBaseURL: nil,
                preferredBonjourServiceHint: "personal",
                lastDiscoveredBonjourURL: "http://10.42.0.5:8792",
                lastDiscoveredBonjourToken: "legacy-local-token",
                lastDiscoveredBonjourNetworkPrefix: "10.42.0"
            ),
            KycodeConnectionProfile(
                id: "remote-hub",
                name: "Mi Mac remota",
                mode: .remoteHub,
                remoteBaseURL: "https://relay.example.com/legacy-hub",
                preferredBonjourServiceHint: nil,
                lastDiscoveredBonjourURL: nil,
                lastDiscoveredBonjourToken: nil,
                lastDiscoveredBonjourNetworkPrefix: nil
            ),
        ]
        UserDefaults.standard.set(try JSONEncoder().encode(legacyProfiles), forKey: profilesKey)
        UserDefaults.standard.set("remote-hub", forKey: selectedProfileKey)

        let store = KycodeConnectionStore()

        XCTAssertEqual(store.userSelectableProfiles.map(\.id), ["puky", "personal", "all"])
        XCTAssertEqual(store.selectedProfileId, "personal")
        XCTAssertEqual(store.profiles.first(where: { $0.id == "puky" })?.mode, .ferminCode)
        XCTAssertEqual(
            store.profiles.first(where: { $0.id == "puky" })?.remoteBaseURL,
            "https://relay.example.com/fermin-code-puky"
        )
        XCTAssertNil(store.profiles.first(where: { $0.id == "puky" })?.lastDiscoveredBonjourURL)
        XCTAssertEqual(store.profiles.first(where: { $0.id == "personal" })?.mode, .personal)
        XCTAssertEqual(
            store.profiles.first(where: { $0.id == "personal" })?.remoteBaseURL,
            "https://relay.example.com/fermin-code"
        )
        XCTAssertFalse(store.profiles.contains(where: { $0.id == "this-mac" || $0.id == "remote-hub" }))
    }

    @MainActor
    func testPersistedPukySelectionRemainsAvailableOnRustRelay() {
        UserDefaults.standard.removeObject(forKey: profilesKey)
        UserDefaults.standard.set("puky", forKey: selectedProfileKey)

        let store = KycodeConnectionStore()

        XCTAssertEqual(store.selectedProfileId, "puky")
        XCTAssertEqual(UserDefaults.standard.string(forKey: selectedProfileKey), "puky")
        XCTAssertEqual(store.userSelectableProfiles.map(\.id), ["puky", "personal", "all"])
        XCTAssertEqual(store.profiles.first(where: { $0.id == "puky" })?.mode, .ferminCode)
        XCTAssertEqual(
            store.profiles.first(where: { $0.id == "puky" })?.remoteBaseURL,
            "https://relay.example.com/fermin-code-puky"
        )
    }

    @MainActor
    func testRustPukyMigrationReplacesLegacyTokenWithSharedPersonalToken() {
        UserDefaults.standard.set(2, forKey: credentialMigrationVersionKey)
        KycodeKeychain.saveAuthToken("legacy-puky-token", profileId: "puky")
        KycodeKeychain.saveAuthToken("shared-rust-mobile-token", profileId: "personal")

        _ = KycodeConnectionStore()

        XCTAssertEqual(
            KycodeKeychain.loadAuthToken(profileId: "puky"),
            "shared-rust-mobile-token"
        )
        XCTAssertEqual(UserDefaults.standard.integer(forKey: credentialMigrationVersionKey), 3)
    }

    func testCombinedModeKeepsSourceIdentityDeduplicatesPerMacAndSortsDeterministically() {
        let combined = KycodeCombinedSessionPolicy.combine([
            KycodeCombinedSessionSource(
                profileId: "puky",
                profileName: "Puky",
                items: [
                    makeSummary(windowId: "shared", updatedAt: 100, displayName: "Puky vieja"),
                    makeSummary(windowId: "shared", updatedAt: 300, displayName: "Puky nueva"),
                    makeSummary(windowId: "same-time", updatedAt: 200, displayName: "Puky empate"),
                ]
            ),
            KycodeCombinedSessionSource(
                profileId: "personal",
                profileName: "Mac personal",
                items: [
                    makeSummary(windowId: "shared", updatedAt: 250, displayName: "Personal"),
                    makeSummary(windowId: "same-time", updatedAt: 200, displayName: "Personal empate"),
                ]
            ),
        ])

        XCTAssertEqual(
            combined.map { $0.summary.windowId },
            ["puky::shared", "personal::shared", "personal::same-time", "puky::same-time"]
        )
        XCTAssertEqual(combined.first?.summary.displayName, "Puky nueva")
        XCTAssertEqual(Set(combined.map(\.remoteWindowId)), ["shared", "same-time"])
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: combined.map { ($0.summary.windowId, $0.profileName) })["personal::shared"],
            "Mac personal"
        )
    }

    @MainActor
    func testTodoRoutesSameRemoteWindowToEachCanonicalRustHostWithoutMixing() async throws {
        UserDefaults.standard.removeObject(forKey: profilesKey)
        UserDefaults.standard.set("all", forKey: selectedProfileKey)
        KycodeKeychain.saveAuthToken("puky-routing-token", profileId: "puky")
        KycodeKeychain.saveAuthToken("personal-routing-token", profileId: "personal")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KycodeMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        var observedRequests: [URLRequest] = []
        let now = Date().timeIntervalSince1970 * 1_000
        defer {
            KycodeMockURLProtocol.handler = nil
            session.invalidateAndCancel()
        }

        KycodeMockURLProtocol.handler = { [self] request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            XCTAssertEqual(url.host, "relay.example.com")
            let isPersonal = url.path.hasPrefix("/fermin-code/")
            XCTAssertTrue(isPersonal || url.path.hasPrefix("/fermin-code-puky/"))
            let summary = makeSummary(
                windowId: "shared-window",
                updatedAt: isPersonal ? now : now - 1,
                displayName: isPersonal ? "Personal shared" : "Puky shared"
            )

            if request.httpMethod == "GET", url.path.hasSuffix("/api/mobile/sessions") {
                return (
                    response,
                    try JSONEncoder().encode(
                        KycodeSessionsEnvelope(
                            ok: true,
                            now: now,
                            exportedAt: nil,
                            items: [summary]
                        )
                    )
                )
            }
            if request.httpMethod == "GET", url.path.hasSuffix("/api/mobile/sessions/shared-window") {
                return (
                    response,
                    try JSONEncoder().encode(
                        KycodeSessionDetailEnvelope(ok: true, now: now, item: summary)
                    )
                )
            }
            if request.httpMethod == "POST", url.path.hasSuffix("/api/mobile/sessions/shared-window/message") {
                return (
                    response,
                    Data(
                        """
                        {"ok":true,"commandId":"cmd-\(isPersonal ? "personal" : "puky")","commandState":"accepted","inserted":true,"durable":true,"queuedAt":\(now)}
                        """.utf8
                    )
                )
            }
            throw URLError(.badURL)
        }

        let previousForceInternet = ProcessInfo.processInfo.environment["KYCODE_UI_TEST_FORCE_INTERNET"]
        setenv("KYCODE_UI_TEST_FORCE_INTERNET", "1", 1)
        defer {
            if let previousForceInternet {
                setenv("KYCODE_UI_TEST_FORCE_INTERNET", previousForceInternet, 1)
            } else {
                unsetenv("KYCODE_UI_TEST_FORCE_INTERNET")
            }
        }

        let store = KycodeConnectionStore(
            urlSession: session,
            requestObserver: { observedRequests.append($0) },
            initialProfileIdOverride: "all"
        )
        await store.retryAutoConnect()

        XCTAssertTrue(store.isConnected)
        XCTAssertEqual(
            Set(store.sessions.map(\.windowId)),
            Set(["personal::shared-window", "puky::shared-window"])
        )
        XCTAssertEqual(
            Set(store.sourceConnectionStates.filter(\.isConnected).map(\.id)),
            Set(["personal", "puky"])
        )
        XCTAssertEqual(store.sessionSourceLabel(for: "personal::shared-window"), "Mac personal")
        XCTAssertEqual(store.sessionSourceLabel(for: "puky::shared-window"), "Puky")

        let personalResult = await store.sendMessage(
            windowId: "personal::shared-window",
            text: "PERSONAL_ROUTE_MARKER"
        )
        let pukyResult = await store.sendMessage(
            windowId: "puky::shared-window",
            text: "PUKY_ROUTE_MARKER"
        )
        XCTAssertTrue(personalResult.sent, personalResult.errorMessage ?? "Personal routing failed")
        XCTAssertTrue(pukyResult.sent, pukyResult.errorMessage ?? "Puky routing failed")

        let messageRequests = observedRequests.filter {
            $0.httpMethod == "POST" && $0.url?.path.hasSuffix("/message") == true
        }
        XCTAssertEqual(messageRequests.count, 2)
        var markerByRoute: [String: String] = [:]
        var authorizationByRoute: [String: String] = [:]
        for request in messageRequests {
            let url = try XCTUnwrap(request.url)
            let body = try XCTUnwrap(request.httpBody)
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            XCTAssertEqual(url.host, "relay.example.com")
            let routeId = url.path.hasPrefix("/fermin-code-puky/") ? "puky" : "personal"
            markerByRoute[routeId] = try XCTUnwrap(object["message"] as? String)
            authorizationByRoute[routeId] = request.value(forHTTPHeaderField: "Authorization")
            XCTAssertEqual(
                url.path,
                routeId == "personal"
                    ? "/fermin-code/api/mobile/sessions/shared-window/message"
                    : "/fermin-code-puky/api/mobile/sessions/shared-window/message"
            )
            XCTAssertFalse(url.path.contains("personal::"))
            XCTAssertFalse(url.path.contains("puky::"))
        }
        XCTAssertEqual(
            markerByRoute,
            [
                "personal": "PERSONAL_ROUTE_MARKER",
                "puky": "PUKY_ROUTE_MARKER",
            ]
        )
        XCTAssertEqual(authorizationByRoute["personal"], "Bearer personal-routing-token")
        XCTAssertEqual(authorizationByRoute["puky"], "Bearer puky-routing-token")
        store.disconnect()
    }

    @MainActor
    func testPromptImproverVariantRefreshesPerProfileAfterHandoff() async throws {
        UserDefaults.standard.removeObject(forKey: profilesKey)
        UserDefaults.standard.set("personal", forKey: selectedProfileKey)
        KycodeKeychain.saveAuthToken("personal-prompt-token", profileId: "personal")
        KycodeKeychain.saveAuthToken("puky-prompt-token", profileId: "puky")

        let suiteName = "KycodePromptImproverHandoffTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KycodeMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let requestsLock = NSLock()
        var promptRequests: [(route: String, method: String)] = []
        let previousForceInternet = ProcessInfo.processInfo.environment["KYCODE_UI_TEST_FORCE_INTERNET"]
        setenv("KYCODE_UI_TEST_FORCE_INTERNET", "1", 1)

        func promptPreferenceData(_ variant: KycodePromptImproverVariant) -> Data {
            Data(
                #"{"ok":true,"preference":{"version":1,"variant":"\#(variant.rawValue)","updatedAt":"2026-08-17T11:00:00.000Z"},"variants":["standard","motivational"]}"#.utf8
            )
        }

        KycodeMockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            if url.path.hasSuffix("/api/mobile/preferences/prompt-improver") {
                let route = url.path.hasPrefix("/fermin-code-puky/") ? "puky" : "personal"
                requestsLock.withLock {
                    promptRequests.append((route, request.httpMethod ?? ""))
                }
                return (
                    response,
                    promptPreferenceData(route == "personal" ? .standard : .motivational)
                )
            }
            if url.path.hasSuffix("/api/mobile/sessions") {
                return (
                    response,
                    try JSONEncoder().encode(
                        KycodeSessionsEnvelope(
                            ok: true,
                            now: Date().timeIntervalSince1970 * 1_000,
                            exportedAt: nil,
                            items: []
                        )
                    )
                )
            }
            return (response, Data())
        }

        let store = KycodeConnectionStore(
            urlSession: session,
            initialProfileIdOverride: "personal",
            runtimeSettingsDefaults: defaults
        )
        defer {
            store.disconnect()
            KycodeMockURLProtocol.handler = nil
            session.invalidateAndCancel()
            defaults.removePersistentDomain(forName: suiteName)
            if let previousForceInternet {
                setenv("KYCODE_UI_TEST_FORCE_INTERNET", previousForceInternet, 1)
            } else {
                unsetenv("KYCODE_UI_TEST_FORCE_INTERNET")
            }
        }

        await store.retryAutoConnect()
        await store.refreshPromptImproverVariant()
        XCTAssertEqual(store.selectedProfileId, "personal")
        XCTAssertEqual(store.promptImproverVariantSelection, .standard)
        XCTAssertEqual(store.promptImproverVariantSyncState, .synchronized)
        XCTAssertTrue(store.promptImproverVariantAccessibilityValue.contains("Mac personal"))

        await store.selectProfile(id: "puky")
        await waitForPromptImproverVariant(.motivational, in: store)
        XCTAssertEqual(store.selectedProfileId, "puky")
        XCTAssertEqual(store.promptImproverVariantSelection, .motivational)
        XCTAssertEqual(store.promptImproverVariantSyncState, .synchronized)
        XCTAssertTrue(store.promptImproverVariantAccessibilityValue.contains("Puky"))
        XCTAssertEqual(
            KycodePromptImproverPreferenceStore.load(profileId: "personal", from: defaults),
            .standard
        )
        XCTAssertEqual(
            KycodePromptImproverPreferenceStore.load(profileId: "puky", from: defaults),
            .motivational
        )
        XCTAssertEqual(
            requestsLock.withLock { promptRequests.map { "\($0.route):\($0.method)" } },
            ["personal:GET", "puky:GET"]
        )
    }

    @MainActor
    func testProfileHandoffReturnsWhilePromptImproverRefreshRemainsInFlight() async throws {
        UserDefaults.standard.removeObject(forKey: profilesKey)
        UserDefaults.standard.set("personal", forKey: selectedProfileKey)
        KycodeKeychain.saveAuthToken("personal-prompt-nonblocking-token", profileId: "personal")
        KycodeKeychain.saveAuthToken("puky-prompt-nonblocking-token", profileId: "puky")

        let suiteName = "KycodePromptImproverNonblockingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KycodeDeferredSendURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let pukyPromptStarted = expectation(description: "Puky prompt preference refresh started")
        let handoffReturned = expectation(description: "Profile handoff returned")
        let pukyPromptGate = KycodeDeferredRequestGate()
        let previousForceInternet = ProcessInfo.processInfo.environment["KYCODE_UI_TEST_FORCE_INTERNET"]
        setenv("KYCODE_UI_TEST_FORCE_INTERNET", "1", 1)

        let preferenceData = Data(
            #"{"ok":true,"preference":{"version":1,"variant":"motivational","updatedAt":"2026-08-17T12:10:00.000Z"},"variants":["standard","motivational"]}"#.utf8
        )
        KycodeDeferredSendURLProtocol.handler = { requestProtocol, request in
            do {
                let url = try XCTUnwrap(request.url)
                if request.httpMethod == "GET",
                   url.path.hasPrefix("/fermin-code-puky/"),
                   url.path.hasSuffix("/api/mobile/preferences/prompt-improver") {
                    pukyPromptGate.hold(requestProtocol)
                    pukyPromptStarted.fulfill()
                    return
                }
                if url.path.hasSuffix("/api/mobile/sessions") {
                    requestProtocol.succeed(
                        data: try JSONEncoder().encode(
                            KycodeSessionsEnvelope(
                                ok: true,
                                now: Date().timeIntervalSince1970 * 1_000,
                                exportedAt: nil,
                                items: []
                            )
                        )
                    )
                    return
                }
                requestProtocol.succeed(data: Data())
            } catch {
                requestProtocol.fail(with: error)
            }
        }

        let store = KycodeConnectionStore(
            urlSession: session,
            initialProfileIdOverride: "personal",
            runtimeSettingsDefaults: defaults
        )
        defer {
            pukyPromptGate.fail(with: URLError(.cancelled))
            store.disconnect()
            KycodeDeferredSendURLProtocol.handler = nil
            session.invalidateAndCancel()
            defaults.removePersistentDomain(forName: suiteName)
            if let previousForceInternet {
                setenv("KYCODE_UI_TEST_FORCE_INTERNET", previousForceInternet, 1)
            } else {
                unsetenv("KYCODE_UI_TEST_FORCE_INTERNET")
            }
        }

        let handoff = Task { @MainActor in
            await store.selectProfile(id: "puky")
            handoffReturned.fulfill()
        }
        await fulfillment(of: [handoffReturned, pukyPromptStarted], timeout: 2)

        XCTAssertEqual(store.selectedProfileId, "puky")
        XCTAssertTrue(store.isConnected)
        XCTAssertTrue(store.isRefreshingPromptImproverVariant)

        pukyPromptGate.succeed(data: preferenceData)
        await handoff.value
        await waitForPromptImproverVariant(.motivational, in: store)
        XCTAssertEqual(store.promptImproverVariantSelection, .motivational)
        XCTAssertEqual(store.promptImproverVariantSyncState, .synchronized)
        XCTAssertFalse(store.isRefreshingPromptImproverVariant)
    }

    @MainActor
    func testQueuedPromptImproverVariantCannotRetargetOrPolluteAfterHandoff() async throws {
        UserDefaults.standard.removeObject(forKey: profilesKey)
        UserDefaults.standard.set("personal", forKey: selectedProfileKey)
        KycodeKeychain.saveAuthToken("personal-prompt-owner-token", profileId: "personal")
        KycodeKeychain.saveAuthToken("puky-prompt-owner-token", profileId: "puky")

        let suiteName = "KycodePromptImproverOwnerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KycodeDeferredSendURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let personalPutStarted = expectation(description: "Personal prompt preference PUT started")
        let personalPutGate = KycodeDeferredRequestGate()
        let requestsLock = NSLock()
        var putRoutes: [String] = []
        let previousForceInternet = ProcessInfo.processInfo.environment["KYCODE_UI_TEST_FORCE_INTERNET"]
        setenv("KYCODE_UI_TEST_FORCE_INTERNET", "1", 1)

        func promptPreferenceData(_ variant: KycodePromptImproverVariant) -> Data {
            Data(
                #"{"ok":true,"preference":{"version":1,"variant":"\#(variant.rawValue)","updatedAt":"2026-08-17T11:10:00.000Z"},"variants":["standard","motivational"]}"#.utf8
            )
        }

        KycodeDeferredSendURLProtocol.handler = { requestProtocol, request in
            do {
                let url = try XCTUnwrap(request.url)
                let isPuky = url.path.hasPrefix("/fermin-code-puky/")
                let route = isPuky ? "puky" : "personal"
                if url.path.hasSuffix("/api/mobile/preferences/prompt-improver") {
                    if request.httpMethod == "PUT" {
                        requestsLock.withLock { putRoutes.append(route) }
                        guard route == "personal" else {
                            requestProtocol.fail(with: URLError(.badURL))
                            return
                        }
                        personalPutGate.hold(requestProtocol)
                        personalPutStarted.fulfill()
                        return
                    }
                    requestProtocol.succeed(
                        data: promptPreferenceData(route == "personal" ? .standard : .motivational)
                    )
                    return
                }
                if url.path.hasSuffix("/api/mobile/sessions") {
                    requestProtocol.succeed(
                        data: try JSONEncoder().encode(
                            KycodeSessionsEnvelope(
                                ok: true,
                                now: Date().timeIntervalSince1970 * 1_000,
                                exportedAt: nil,
                                items: []
                            )
                        )
                    )
                    return
                }
                requestProtocol.succeed(data: Data())
            } catch {
                requestProtocol.fail(with: error)
            }
        }

        let store = KycodeConnectionStore(
            urlSession: session,
            initialProfileIdOverride: "personal",
            runtimeSettingsDefaults: defaults
        )
        defer {
            personalPutGate.fail(with: URLError(.cancelled))
            store.disconnect()
            KycodeDeferredSendURLProtocol.handler = nil
            session.invalidateAndCancel()
            defaults.removePersistentDomain(forName: suiteName)
            if let previousForceInternet {
                setenv("KYCODE_UI_TEST_FORCE_INTERNET", previousForceInternet, 1)
            } else {
                unsetenv("KYCODE_UI_TEST_FORCE_INTERNET")
            }
        }

        await store.retryAutoConnect()
        await store.refreshPromptImproverVariant()
        XCTAssertEqual(store.promptImproverVariantSelection, .standard)

        let firstMutation = Task { @MainActor in
            await store.setPromptImproverVariant(.motivational)
        }
        await fulfillment(of: [personalPutStarted], timeout: 2)
        let queuedResult = await store.setPromptImproverVariant(.standard)
        XCTAssertTrue(queuedResult)

        let relaunchedWhilePending = KycodeConnectionStore(
            initialProfileIdOverride: "personal",
            runtimeSettingsDefaults: defaults
        )
        XCTAssertEqual(relaunchedWhilePending.promptImproverVariantSelection, .standard)
        XCTAssertEqual(relaunchedWhilePending.promptImproverVariantSyncState, .cached)

        await store.selectProfile(id: "puky")
        await waitForPromptImproverVariant(.motivational, in: store)
        XCTAssertEqual(store.promptImproverVariantSelection, .motivational)
        XCTAssertEqual(store.promptImproverVariantSyncState, .synchronized)
        store.errorMessage = nil

        personalPutGate.fail(with: URLError(.cannotConnectToHost))
        _ = await firstMutation.value

        XCTAssertEqual(requestsLock.withLock { putRoutes }, ["personal"])
        XCTAssertEqual(store.selectedProfileId, "puky")
        XCTAssertEqual(store.promptImproverVariantSelection, .motivational)
        XCTAssertEqual(store.promptImproverVariantSyncState, .synchronized)
        XCTAssertNil(store.errorMessage, "Personal's late failure must not pollute Puky feedback.")
        XCTAssertEqual(
            KycodePromptImproverPreferenceStore.load(profileId: "personal", from: defaults),
            .standard
        )
        XCTAssertEqual(
            KycodePromptImproverPreferenceStore.load(profileId: "puky", from: defaults),
            .motivational
        )
    }

    @MainActor
    func testPromptImproverVariantDisconnectDuringPutAllowsImmediateReconnect() async throws {
        UserDefaults.standard.removeObject(forKey: profilesKey)
        UserDefaults.standard.set("personal", forKey: selectedProfileKey)
        KycodeKeychain.saveAuthToken("personal-prompt-reconnect-token", profileId: "personal")

        let suiteName = "KycodePromptImproverReconnectTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KycodeDeferredSendURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let firstPutStarted = expectation(description: "First prompt preference PUT started")
        let firstPutGate = KycodeDeferredRequestGate()
        let requestsLock = NSLock()
        var putCount = 0
        let previousForceInternet = ProcessInfo.processInfo.environment["KYCODE_UI_TEST_FORCE_INTERNET"]
        setenv("KYCODE_UI_TEST_FORCE_INTERNET", "1", 1)

        func promptPreferenceData(_ variant: KycodePromptImproverVariant) -> Data {
            Data(
                #"{"ok":true,"preference":{"version":1,"variant":"\#(variant.rawValue)","updatedAt":"2026-08-17T11:30:00.000Z"},"variants":["standard","motivational"]}"#.utf8
            )
        }

        KycodeDeferredSendURLProtocol.handler = { requestProtocol, request in
            do {
                let url = try XCTUnwrap(request.url)
                if url.path.hasSuffix("/api/mobile/preferences/prompt-improver") {
                    if request.httpMethod == "PUT" {
                        let ordinal = requestsLock.withLock {
                            putCount += 1
                            return putCount
                        }
                        if ordinal == 1 {
                            firstPutGate.hold(requestProtocol)
                            firstPutStarted.fulfill()
                        } else {
                            requestProtocol.succeed(data: promptPreferenceData(.standard))
                        }
                        return
                    }
                    requestProtocol.succeed(data: promptPreferenceData(.standard))
                    return
                }
                if url.path.hasSuffix("/api/mobile/sessions") {
                    requestProtocol.succeed(
                        data: try JSONEncoder().encode(
                            KycodeSessionsEnvelope(
                                ok: true,
                                now: Date().timeIntervalSince1970 * 1_000,
                                exportedAt: nil,
                                items: []
                            )
                        )
                    )
                    return
                }
                requestProtocol.succeed(data: Data())
            } catch {
                requestProtocol.fail(with: error)
            }
        }

        let store = KycodeConnectionStore(
            urlSession: session,
            initialProfileIdOverride: "personal",
            runtimeSettingsDefaults: defaults
        )
        defer {
            firstPutGate.fail(with: URLError(.cancelled))
            store.disconnect()
            KycodeDeferredSendURLProtocol.handler = nil
            session.invalidateAndCancel()
            defaults.removePersistentDomain(forName: suiteName)
            if let previousForceInternet {
                setenv("KYCODE_UI_TEST_FORCE_INTERNET", previousForceInternet, 1)
            } else {
                unsetenv("KYCODE_UI_TEST_FORCE_INTERNET")
            }
        }

        await store.retryAutoConnect()
        await store.refreshPromptImproverVariant()
        let staleMutation = Task { @MainActor in
            await store.setPromptImproverVariant(.motivational)
        }
        await fulfillment(of: [firstPutStarted], timeout: 2)
        XCTAssertTrue(store.isUpdatingPromptImproverVariant)

        store.disconnect()
        XCTAssertFalse(store.isUpdatingPromptImproverVariant)
        XCTAssertFalse(store.isRefreshingPromptImproverVariant)

        await store.retryAutoConnect()
        await store.refreshPromptImproverVariant()
        XCTAssertEqual(store.promptImproverVariantSyncState, .synchronized)
        let newMutationSucceeded = await store.setPromptImproverVariant(.standard)
        XCTAssertTrue(newMutationSucceeded)
        XCTAssertEqual(requestsLock.withLock { putCount }, 2)

        store.errorMessage = nil
        firstPutGate.succeed(data: promptPreferenceData(.motivational))
        _ = await staleMutation.value
        XCTAssertFalse(store.isUpdatingPromptImproverVariant)
        XCTAssertFalse(store.isRefreshingPromptImproverVariant)
        XCTAssertEqual(store.promptImproverVariantSelection, .standard)
        XCTAssertEqual(store.promptImproverVariantSyncState, .synchronized)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(
            KycodePromptImproverPreferenceStore.load(profileId: "personal", from: defaults),
            .standard,
            "The stale ACK must not overwrite the newer confirmed preference."
        )
    }

    @MainActor
    func testPromptImproverVariantLatestRefreshWinsForSameRuntime() async throws {
        UserDefaults.standard.removeObject(forKey: profilesKey)
        UserDefaults.standard.set("personal", forKey: selectedProfileKey)
        KycodeKeychain.saveAuthToken("personal-prompt-refresh-token", profileId: "personal")

        let suiteName = "KycodePromptImproverRefreshTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KycodeDeferredSendURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let firstRefreshStarted = expectation(description: "First prompt preference refresh started")
        let firstRefreshGate = KycodeDeferredRequestGate()
        let requestsLock = NSLock()
        var refreshCount = 0
        let previousForceInternet = ProcessInfo.processInfo.environment["KYCODE_UI_TEST_FORCE_INTERNET"]
        setenv("KYCODE_UI_TEST_FORCE_INTERNET", "1", 1)

        func promptPreferenceData(_ variant: KycodePromptImproverVariant) -> Data {
            Data(
                #"{"ok":true,"preference":{"version":1,"variant":"\#(variant.rawValue)","updatedAt":"2026-08-17T11:40:00.000Z"},"variants":["standard","motivational"]}"#.utf8
            )
        }

        KycodeDeferredSendURLProtocol.handler = { requestProtocol, request in
            do {
                let url = try XCTUnwrap(request.url)
                if request.httpMethod == "GET",
                   url.path.hasSuffix("/api/mobile/preferences/prompt-improver") {
                    let ordinal = requestsLock.withLock {
                        refreshCount += 1
                        return refreshCount
                    }
                    if ordinal == 1 {
                        firstRefreshGate.hold(requestProtocol)
                        firstRefreshStarted.fulfill()
                    } else {
                        requestProtocol.succeed(data: promptPreferenceData(.motivational))
                    }
                    return
                }
                if url.path.hasSuffix("/api/mobile/sessions") {
                    requestProtocol.succeed(
                        data: try JSONEncoder().encode(
                            KycodeSessionsEnvelope(
                                ok: true,
                                now: Date().timeIntervalSince1970 * 1_000,
                                exportedAt: nil,
                                items: []
                            )
                        )
                    )
                    return
                }
                requestProtocol.succeed(data: Data())
            } catch {
                requestProtocol.fail(with: error)
            }
        }

        let store = KycodeConnectionStore(
            urlSession: session,
            initialProfileIdOverride: "personal",
            runtimeSettingsDefaults: defaults
        )
        defer {
            firstRefreshGate.fail(with: URLError(.cancelled))
            store.disconnect()
            KycodeDeferredSendURLProtocol.handler = nil
            session.invalidateAndCancel()
            defaults.removePersistentDomain(forName: suiteName)
            if let previousForceInternet {
                setenv("KYCODE_UI_TEST_FORCE_INTERNET", previousForceInternet, 1)
            } else {
                unsetenv("KYCODE_UI_TEST_FORCE_INTERNET")
            }
        }

        await store.retryAutoConnect()
        let staleRefresh = Task { @MainActor in
            await store.refreshPromptImproverVariant()
        }
        await fulfillment(of: [firstRefreshStarted], timeout: 2)
        await store.refreshPromptImproverVariant()
        XCTAssertEqual(store.promptImproverVariantSelection, .motivational)
        XCTAssertEqual(store.promptImproverVariantSyncState, .synchronized)

        firstRefreshGate.succeed(data: promptPreferenceData(.standard))
        await staleRefresh.value
        XCTAssertEqual(requestsLock.withLock { refreshCount }, 2)
        XCTAssertEqual(store.promptImproverVariantSelection, .motivational)
        XCTAssertEqual(store.promptImproverVariantSyncState, .synchronized)
        XCTAssertEqual(
            KycodePromptImproverPreferenceStore.load(profileId: "personal", from: defaults),
            .motivational
        )
    }

    @MainActor
    func testPromptImproverVariantAllShowsMixedUntilExplicitlyUnified() async throws {
        UserDefaults.standard.removeObject(forKey: profilesKey)
        UserDefaults.standard.set("all", forKey: selectedProfileKey)
        KycodeKeychain.saveAuthToken("personal-prompt-all-token", profileId: "personal")
        KycodeKeychain.saveAuthToken("puky-prompt-all-token", profileId: "puky")

        let suiteName = "KycodePromptImproverAllTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KycodeMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let requestsLock = NSLock()
        var putRoutes: [String] = []
        var shouldFailPukyPut = true
        let previousForceInternet = ProcessInfo.processInfo.environment["KYCODE_UI_TEST_FORCE_INTERNET"]
        setenv("KYCODE_UI_TEST_FORCE_INTERNET", "1", 1)

        func promptPreferenceData(_ variant: KycodePromptImproverVariant) -> Data {
            Data(
                #"{"ok":true,"preference":{"version":1,"variant":"\#(variant.rawValue)","updatedAt":"2026-08-17T11:20:00.000Z"},"variants":["standard","motivational"]}"#.utf8
            )
        }

        KycodeMockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            let route = url.path.hasPrefix("/fermin-code-puky/") ? "puky" : "personal"
            if url.path.hasSuffix("/api/mobile/preferences/prompt-improver") {
                if request.httpMethod == "PUT" {
                    let shouldFail = requestsLock.withLock {
                        putRoutes.append(route)
                        return route == "puky" && shouldFailPukyPut
                    }
                    let body = try JSONSerialization.jsonObject(
                        with: kycodeRequestBodyData(request)
                    ) as? [String: Any]
                    XCTAssertEqual(body?["variant"] as? String, "standard")
                    if shouldFail {
                        throw URLError(.cannotConnectToHost)
                    }
                    return (response, promptPreferenceData(.standard))
                }
                return (
                    response,
                    promptPreferenceData(route == "personal" ? .standard : .motivational)
                )
            }
            if url.path.hasSuffix("/api/mobile/sessions") {
                return (
                    response,
                    try JSONEncoder().encode(
                        KycodeSessionsEnvelope(
                            ok: true,
                            now: Date().timeIntervalSince1970 * 1_000,
                            exportedAt: nil,
                            items: []
                        )
                    )
                )
            }
            return (response, Data())
        }

        let store = KycodeConnectionStore(
            urlSession: session,
            initialProfileIdOverride: "all",
            runtimeSettingsDefaults: defaults
        )
        defer {
            store.disconnect()
            KycodeMockURLProtocol.handler = nil
            session.invalidateAndCancel()
            defaults.removePersistentDomain(forName: suiteName)
            if let previousForceInternet {
                setenv("KYCODE_UI_TEST_FORCE_INTERNET", previousForceInternet, 1)
            } else {
                unsetenv("KYCODE_UI_TEST_FORCE_INTERNET")
            }
        }

        await store.retryAutoConnect()
        await store.refreshPromptImproverVariant()
        XCTAssertEqual(store.promptImproverVariantSyncState, .mixed)
        XCTAssertNil(store.promptImproverVariantSelection)
        XCTAssertTrue(store.promptImproverVariantSummary.contains("tipos distintos"))
        XCTAssertTrue(store.promptImproverVariantStatusText.contains("unificar"))
        XCTAssertTrue(store.promptImproverVariantAccessibilityValue.contains("Configuraciones diferentes"))

        let partialResult = await store.setPromptImproverVariant(.standard)
        XCTAssertFalse(partialResult)
        XCTAssertEqual(store.promptImproverVariantSyncState, .partial)
        XCTAssertNil(store.promptImproverVariantSelection)
        XCTAssertTrue(store.promptImproverVariantStatusText.contains("No pudimos confirmar ambos"))
        XCTAssertEqual(requestsLock.withLock { putRoutes }, ["personal", "puky"])
        XCTAssertEqual(
            KycodePromptImproverPreferenceStore.load(profileId: "personal", from: defaults),
            .standard
        )
        XCTAssertEqual(
            KycodePromptImproverPreferenceStore.load(profileId: "puky", from: defaults),
            .motivational
        )

        requestsLock.withLock {
            shouldFailPukyPut = false
            putRoutes.removeAll()
        }
        store.errorMessage = nil
        let didUnify = await store.setPromptImproverVariant(.standard)
        XCTAssertTrue(didUnify)
        XCTAssertEqual(store.promptImproverVariantSyncState, .synchronized)
        XCTAssertEqual(store.promptImproverVariantSelection, .standard)
        XCTAssertEqual(requestsLock.withLock { putRoutes }, ["personal", "puky"])
        XCTAssertEqual(
            KycodePromptImproverPreferenceStore.load(profileId: "personal", from: defaults),
            .standard
        )
        XCTAssertEqual(
            KycodePromptImproverPreferenceStore.load(profileId: "puky", from: defaults),
            .standard
        )
    }

    @MainActor
    func testLatePersonalDetailCannotOverwritePukyAfterProfileHandoff() async throws {
        UserDefaults.standard.removeObject(forKey: profilesKey)
        UserDefaults.standard.set("personal", forKey: selectedProfileKey)
        KycodeKeychain.saveAuthToken("personal-route-token", profileId: "personal")
        KycodeKeychain.saveAuthToken("puky-route-token", profileId: "puky")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KycodeDeferredSendURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let personalDetailStarted = expectation(description: "Personal detail started")
        let personalDetailGate = KycodeDeferredRequestGate()
        let now = Date().timeIntervalSince1970 * 1_000
        let previousForceInternet = ProcessInfo.processInfo.environment["KYCODE_UI_TEST_FORCE_INTERNET"]
        defer {
            personalDetailGate.fail(with: URLError(.cancelled))
            KycodeDeferredSendURLProtocol.handler = nil
            session.invalidateAndCancel()
            if let previousForceInternet {
                setenv("KYCODE_UI_TEST_FORCE_INTERNET", previousForceInternet, 1)
            } else {
                unsetenv("KYCODE_UI_TEST_FORCE_INTERNET")
            }
        }

        KycodeDeferredSendURLProtocol.handler = { [self] requestProtocol, request in
            do {
                let url = try XCTUnwrap(request.url)
                let isPersonal = url.path.hasPrefix("/fermin-code/")
                let source = isPersonal ? "PERSONAL" : "PUKY"
                let summary = makeSummary(
                    windowId: "shared-window",
                    updatedAt: isPersonal ? now : now + 1,
                    displayName: "\(source) summary"
                )

                if request.httpMethod == "GET", url.path.hasSuffix("/api/mobile/stream") {
                    // Keep the simulated SSE request open. Letting it fail here
                    // starts the production reconnect loop and makes this
                    // profile-handoff fixture observe unrelated recovery work.
                    return
                }
                if request.httpMethod == "GET", url.path.hasSuffix("/api/mobile/sessions") {
                    requestProtocol.succeed(
                        data: try JSONEncoder().encode(
                            KycodeSessionsEnvelope(ok: true, now: now, exportedAt: nil, items: [summary])
                        )
                    )
                    return
                }
                if request.httpMethod == "GET",
                   url.path.hasSuffix("/api/mobile/sessions/shared-window") {
                    let message = KycodeMessage(
                        id: "\(source.lowercased())-message",
                        role: "assistant",
                        type: "text",
                        content: isPersonal ? "PERSONAL_LATE" : "PUKY_CURRENT",
                        originalPrompt: nil,
                        transformedPrompt: nil,
                        improvedPrompt: nil,
                        timestamp: now,
                        status: "completed",
                        imageAttachments: nil
                    )
                    let detailData = try JSONEncoder().encode(
                        KycodeSessionDetailEnvelope(
                            ok: true,
                            now: now,
                            item: makeSummary(
                                windowId: "shared-window",
                                updatedAt: isPersonal ? now : now + 1,
                                displayName: "\(source) detail",
                                messages: [message]
                            )
                        )
                    )
                    if isPersonal {
                        personalDetailGate.hold(requestProtocol)
                        personalDetailStarted.fulfill()
                    } else {
                        requestProtocol.succeed(data: detailData)
                    }
                    return
                }
                if request.httpMethod == "GET",
                   url.path.hasSuffix("/api/mobile/preferences/prompt-improver") {
                    requestProtocol.succeed(
                        data: Data(
                            #"{"ok":true,"preference":{"version":1,"variant":"standard","updatedAt":"2026-08-17T12:05:00.000Z"},"variants":["standard","motivational"]}"#.utf8
                        )
                    )
                    return
                }
                requestProtocol.fail(with: URLError(.badURL))
            } catch {
                requestProtocol.fail(with: error)
            }
        }

        setenv("KYCODE_UI_TEST_FORCE_INTERNET", "1", 1)
        let store = KycodeConnectionStore(
            urlSession: session,
            initialProfileIdOverride: "personal"
        )
        await store.retryAutoConnect()
        XCTAssertEqual(store.sessions.map(\.windowId), ["shared-window"])

        let personalRefresh = Task { @MainActor in
            await store.refreshDetail(windowId: "shared-window")
        }
        await fulfillment(of: [personalDetailStarted], timeout: 2)

        await store.selectProfile(id: "puky")
        XCTAssertEqual(store.selectedProfileId, "puky")
        await store.refreshDetail(windowId: "shared-window")
        for _ in 0..<100 where
            store.detail(for: "shared-window")?.messages?.first?.content != "PUKY_CURRENT" {
            await Task.yield()
        }
        XCTAssertEqual(store.detail(for: "shared-window")?.messages?.first?.content, "PUKY_CURRENT")

        let personalLateMessage = KycodeMessage(
            id: "personal-message",
            role: "assistant",
            type: "text",
            content: "PERSONAL_LATE",
            originalPrompt: nil,
            transformedPrompt: nil,
            improvedPrompt: nil,
            timestamp: now,
            status: "completed",
            imageAttachments: nil
        )
        personalDetailGate.succeed(
            data: try JSONEncoder().encode(
                KycodeSessionDetailEnvelope(
                    ok: true,
                    now: now,
                    item: makeSummary(
                        windowId: "shared-window",
                        updatedAt: now,
                        displayName: "PERSONAL detail",
                        messages: [personalLateMessage]
                    )
                )
            )
        )
        await personalRefresh.value

        XCTAssertEqual(store.selectedProfileId, "puky")
        XCTAssertEqual(store.detail(for: "shared-window")?.messages?.first?.content, "PUKY_CURRENT")
        XCTAssertNil(store.errorMessage)
        store.disconnect()
    }

    @MainActor
    func testFeatureAckFromPersonalCannotMutateSameWindowOnPukyAfterHandoff() async throws {
        UserDefaults.standard.removeObject(forKey: profilesKey)
        UserDefaults.standard.set("personal", forKey: selectedProfileKey)
        KycodeKeychain.saveAuthToken("personal-feature-token", profileId: "personal")
        KycodeKeychain.saveAuthToken("puky-feature-token", profileId: "puky")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KycodeMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let personalPostStarted = expectation(description: "Personal feature POST started")
        let releasePersonalPost = DispatchSemaphore(value: 0)
        var personalFeaturePostCount = 0
        var pukyFeaturePostCount = 0
        let now = Date().timeIntervalSince1970 * 1_000
        let personalRevision = now
        let pukyRevision = now + 1
        let previousForceInternet = ProcessInfo.processInfo.environment["KYCODE_UI_TEST_FORCE_INTERNET"]
        defer {
            releasePersonalPost.signal()
            session.invalidateAndCancel()
            if let previousForceInternet {
                setenv("KYCODE_UI_TEST_FORCE_INTERNET", previousForceInternet, 1)
            } else {
                unsetenv("KYCODE_UI_TEST_FORCE_INTERNET")
            }
        }

        KycodeMockURLProtocol.handler = { [self] request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            let isPersonal = url.path.hasPrefix("/fermin-code/")
            let summary = makeSummary(
                windowId: "shared-window",
                updatedAt: isPersonal ? personalRevision : pukyRevision,
                displayName: isPersonal ? "Personal shared" : "Puky shared",
                features: KycodeSessionFeatures(
                    promptImproverEnabled: true,
                    explainerEnabled: false,
                    codeContextEnabled: true
                )
            )

            if request.httpMethod == "POST", url.path.hasSuffix("/features") {
                if isPersonal {
                    personalFeaturePostCount += 1
                    personalPostStarted.fulfill()
                    _ = releasePersonalPost.wait(timeout: .now() + 5)
                } else {
                    pukyFeaturePostCount += 1
                }
                return (
                    response,
                    Data(
                        #"{"ok":true,"commandId":"feature-handoff","commandState":"accepted","inserted":true,"durable":true,"queuedAt":1}"#.utf8
                    )
                )
            }
            if request.httpMethod == "GET", url.path.hasSuffix("/api/mobile/sessions") {
                return (
                    response,
                    try JSONEncoder().encode(
                        KycodeSessionsEnvelope(ok: true, now: summary.updatedAt, exportedAt: nil, items: [summary])
                    )
                )
            }
            if request.httpMethod == "GET", url.path.hasSuffix("/api/mobile/sessions/shared-window") {
                return (
                    response,
                    try JSONEncoder().encode(
                        KycodeSessionDetailEnvelope(ok: true, now: summary.updatedAt, item: summary)
                    )
                )
            }
            throw URLError(.badURL)
        }

        setenv("KYCODE_UI_TEST_FORCE_INTERNET", "1", 1)
        let store = KycodeConnectionStore(
            urlSession: session,
            initialProfileIdOverride: "personal"
        )
        await store.retryAutoConnect()
        XCTAssertEqual(
            store.sessions.first?.sessionId,
            "session-shared-window-\(Int(personalRevision))"
        )

        let personalMutation = Task { @MainActor in
            await store.setFeatures(
                windowId: "shared-window",
                promptImproverEnabled: false,
                explainerEnabled: false
            )
        }
        await fulfillment(of: [personalPostStarted], timeout: 2)

        let handoff = Task { @MainActor in
            await store.selectProfile(id: "puky")
        }
        for _ in 0..<100 where store.selectedProfileId != "puky" {
            await Task.yield()
        }
        XCTAssertEqual(store.selectedProfileId, "puky")

        releasePersonalPost.signal()
        let personalMutationSucceeded = await personalMutation.value
        XCTAssertTrue(personalMutationSucceeded)
        await handoff.value

        XCTAssertEqual(store.selectedProfileId, "puky")
        XCTAssertEqual(
            store.sessions.first?.sessionId,
            "session-shared-window-\(Int(pukyRevision))"
        )
        XCTAssertEqual(store.sessions.first?.features?.promptImproverEnabled, true)
        XCTAssertEqual(personalFeaturePostCount, 1)
        XCTAssertEqual(pukyFeaturePostCount, 0)
        XCTAssertNil(store.errorMessage)
        store.disconnect()
    }

    @MainActor
    func testLateSuccessfulSendAfterProfileHandoffCannotMutateCurrentSameWindowState() async throws {
        try await exerciseLateSendAfterProfileHandoff(personalPostFails: false)
    }

    @MainActor
    func testLateFailedSendAfterProfileHandoffCannotMutateCurrentSameWindowState() async throws {
        try await exerciseLateSendAfterProfileHandoff(personalPostFails: true)
    }

    @MainActor
    func testLateVoiceTranscriptCannotRetargetAcrossProfileHandoff() async throws {
        let defaults = UserDefaults.standard
        let previousProfiles = defaults.data(forKey: profilesKey)
        let previousSelectedProfile = defaults.string(forKey: selectedProfileKey)
        let previousPersonalToken = KycodeKeychain.loadAuthToken(profileId: "personal")
        let previousPukyToken = KycodeKeychain.loadAuthToken(profileId: "puky")
        let previousForceInternet = ProcessInfo.processInfo.environment["KYCODE_UI_TEST_FORCE_INTERNET"]
        defaults.removeObject(forKey: profilesKey)
        defaults.set("personal", forKey: selectedProfileKey)
        KycodeKeychain.saveAuthToken("personal-voice-token", profileId: "personal")
        KycodeKeychain.saveAuthToken("puky-voice-token", profileId: "puky")
        setenv("KYCODE_UI_TEST_FORCE_INTERNET", "1", 1)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KycodeDeferredSendURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let now = Date().timeIntervalSince1970 * 1_000
        let personalRevision = now
        let pukyRevision = now + 1
        var messagePostRoutes: [String] = []
        let personalPostStarted = expectation(description: "Personal voice POST started")
        let personalPostGate = KycodeDeferredRequestGate()
        defer {
            personalPostGate.fail(with: URLError(.cancelled))
            KycodeDeferredSendURLProtocol.handler = nil
            session.invalidateAndCancel()
            if let previousProfiles {
                defaults.set(previousProfiles, forKey: profilesKey)
            } else {
                defaults.removeObject(forKey: profilesKey)
            }
            if let previousSelectedProfile {
                defaults.set(previousSelectedProfile, forKey: selectedProfileKey)
            } else {
                defaults.removeObject(forKey: selectedProfileKey)
            }
            if let previousPersonalToken {
                KycodeKeychain.saveAuthToken(previousPersonalToken, profileId: "personal")
            } else {
                KycodeKeychain.deleteAuthToken(profileId: "personal")
            }
            if let previousPukyToken {
                KycodeKeychain.saveAuthToken(previousPukyToken, profileId: "puky")
            } else {
                KycodeKeychain.deleteAuthToken(profileId: "puky")
            }
            if let previousForceInternet {
                setenv("KYCODE_UI_TEST_FORCE_INTERNET", previousForceInternet, 1)
            } else {
                unsetenv("KYCODE_UI_TEST_FORCE_INTERNET")
            }
        }

        KycodeDeferredSendURLProtocol.handler = { [self] requestProtocol, request in
            do {
                let url = try XCTUnwrap(request.url)
                let isPersonal = url.path.hasPrefix("/fermin-code/")
                let revision = isPersonal ? personalRevision : pukyRevision
                let summary = makeSummary(
                    windowId: "shared-window",
                    updatedAt: revision,
                    displayName: isPersonal ? "Personal voice" : "Puky voice"
                )
                if request.httpMethod == "GET", url.path.hasSuffix("/api/mobile/stream") {
                    return
                }
                if request.httpMethod == "GET", url.path.hasSuffix("/api/mobile/sessions") {
                    requestProtocol.succeed(
                        data: try JSONEncoder().encode(
                            KycodeSessionsEnvelope(
                                ok: true,
                                now: revision,
                                exportedAt: nil,
                                items: [summary]
                            )
                        )
                    )
                    return
                }
                if request.httpMethod == "GET",
                   url.path.hasSuffix("/api/mobile/sessions/shared-window") {
                    requestProtocol.succeed(
                        data: try JSONEncoder().encode(
                            KycodeSessionDetailEnvelope(ok: true, now: revision, item: summary)
                        )
                    )
                    return
                }
                if request.httpMethod == "POST", url.path.hasSuffix("/message") {
                    messagePostRoutes.append(isPersonal ? "personal" : "puky")
                    let ackData = Data(
                        """
                        {"ok":true,"commandId":"voice-\(isPersonal ? "personal" : "puky")","commandState":"completed","inserted":true,"durable":true,"queuedAt":\(revision)}
                        """.utf8
                    )
                    if isPersonal {
                        personalPostGate.hold(requestProtocol)
                        personalPostStarted.fulfill()
                    } else {
                        requestProtocol.succeed(data: ackData)
                    }
                    return
                }
                if request.httpMethod == "GET",
                   url.path.hasSuffix("/api/mobile/preferences/prompt-improver") {
                    requestProtocol.succeed(
                        data: Data(
                            #"{"ok":true,"preference":{"version":1,"variant":"standard","updatedAt":"2026-08-17T12:10:00.000Z"},"variants":["standard","motivational"]}"#.utf8
                        )
                    )
                    return
                }
                requestProtocol.fail(with: URLError(.badURL))
            } catch {
                requestProtocol.fail(with: error)
            }
        }

        let store = KycodeConnectionStore(
            urlSession: session,
            initialProfileIdOverride: "personal",
            messageReconciliationSleep: { _ in await Task.yield() }
        )
        await store.retryAutoConnect()
        XCTAssertEqual(
            store.sessions.first?.sessionId,
            "session-shared-window-\(Int(personalRevision))"
        )

        let personalJob = store.beginVoiceTranscription(
            windowId: "shared-window",
            duration: 2
        )
        XCTAssertEqual(personalJob.owner?.route.routedProfileId, "personal")

        await store.selectProfile(id: "puky")
        XCTAssertEqual(store.selectedProfileId, "puky")
        XCTAssertEqual(
            store.sessions.first?.sessionId,
            "session-shared-window-\(Int(pukyRevision))"
        )

        let staleCompletion = await store.completeVoiceTranscription(
            jobId: personalJob.id,
            transcript: "AUDIO_PERSONAL_NO_DEBE_IR_A_PUKY"
        )
        XCTAssertFalse(staleCompletion)
        XCTAssertTrue(messagePostRoutes.isEmpty)
        XCTAssertEqual(store.voiceTranscriptionJobs[personalJob.id]?.phase, .failed)
        XCTAssertTrue(
            store.voiceTranscriptionJobs[personalJob.id]?.errorMessage?.contains("sesión cambió") == true
        )
        XCTAssertEqual(
            store.sessions.first?.sessionId,
            "session-shared-window-\(Int(pukyRevision))"
        )

        let pukyJob = store.beginVoiceTranscription(
            windowId: "shared-window",
            duration: 2
        )
        let currentCompletion = await store.completeVoiceTranscription(
            jobId: pukyJob.id,
            transcript: "AUDIO_PUKY_VALIDO"
        )
        XCTAssertTrue(currentCompletion)
        XCTAssertEqual(messagePostRoutes, ["puky"])
        XCTAssertNil(store.voiceTranscriptionJobs[pukyJob.id])
        XCTAssertNil(store.errorMessage)

        await store.selectProfile(id: "personal")
        XCTAssertEqual(store.selectedProfileId, "personal")
        let inFlightPersonalJob = store.beginVoiceTranscription(
            windowId: "shared-window",
            duration: 2
        )
        let inFlightCompletion = Task { @MainActor in
            await store.completeVoiceTranscription(
                jobId: inFlightPersonalJob.id,
                transcript: "AUDIO_PERSONAL_YA_ENVIANDO"
            )
        }
        await fulfillment(of: [personalPostStarted], timeout: 2)

        await store.selectProfile(id: "puky")
        XCTAssertEqual(store.selectedProfileId, "puky")
        personalPostGate.succeed(
            data: Data(
                """
                {"ok":true,"commandId":"voice-personal","commandState":"completed","inserted":true,"durable":true,"queuedAt":\(personalRevision)}
                """.utf8
            )
        )

        let inFlightResult = await inFlightCompletion.value
        XCTAssertFalse(inFlightResult)
        XCTAssertEqual(messagePostRoutes, ["puky", "personal"])
        XCTAssertEqual(store.voiceTranscriptionJobs[inFlightPersonalJob.id]?.phase, .failed)
        XCTAssertTrue(
            store.voiceTranscriptionJobs[inFlightPersonalJob.id]?.errorMessage?.contains("sesión cambió") == true
        )
        XCTAssertEqual(
            store.sessions.first?.sessionId,
            "session-shared-window-\(Int(pukyRevision))"
        )
        XCTAssertNil(store.errorMessage)
        store.disconnect()
    }

    func testSessionDisplayOrderSurvivesActivityRefreshAndAppendsOnlyNewSessions() {
        XCTAssertEqual(
            KycodeSessionDisplayOrderPolicy.reconcile(
                existingOrder: ["session-b", "session-a", "removed"],
                availableWindowIds: ["session-a", "session-b", "session-c"],
                defaultOrder: ["session-c", "session-a", "session-b"]
            ),
            ["session-b", "session-a", "session-c"]
        )
    }

    func testSessionDisplayOrderChangesOnlyThroughExplicitMove() {
        XCTAssertEqual(
            KycodeSessionDisplayOrderPolicy.moving(
                ["session-a", "session-b", "session-c"],
                windowId: "session-a",
                over: "session-c"
            ),
            ["session-b", "session-c", "session-a"]
        )
        XCTAssertEqual(
            KycodeSessionDisplayOrderPolicy.moving(
                ["session-a", "session-b", "session-c"],
                windowId: "session-c",
                over: "session-a"
            ),
            ["session-c", "session-a", "session-b"]
        )
    }

    func testCanonicalWindowNameWinsOverStaleGenericMobileSessionName() {
        var summary = makeSummary(
            windowId: "recordatorios",
            updatedAt: 100,
            displayName: "recordatorios"
        )
        summary.collaborationProjectName = "fermin"
        summary.sessionName = "Proyecto"

        XCTAssertEqual(summary.collaborationSessionName, "recordatorios")
        XCTAssertEqual(summary.collaborationProjectDisplayName, "fermin")
        XCTAssertEqual(summary.collaborationDisplayName, "fermin: recordatorios")
    }

    @MainActor
    func testReturningToPreviouslyConnectedTargetUsesWarmSnapshotWithoutNetworkWaitAndPreservesSourceMetadata() async throws {
        UserDefaults.standard.removeObject(forKey: profilesKey)
        UserDefaults.standard.set("puky", forKey: selectedProfileKey)
        KycodeKeychain.saveAuthToken("personal-test-token", profileId: "personal")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KycodeMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        var sessionsFetchesByHost: [String: Int] = [:]
        KycodeMockURLProtocol.handler = { [self] request in
            let url = try XCTUnwrap(request.url)
            if url.path == "/api/mobile/stream" {
                throw URLError(.cancelled)
            }
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            let host = url.host ?? "unknown"
            if url.path == "/api/mobile/sessions" {
                sessionsFetchesByHost[host, default: 0] += 1
            }
            let isPersonal = host == "relay.example.com"
            let item = makeSummary(
                windowId: isPersonal ? "personal-window" : "puky-window",
                updatedAt: isPersonal ? 200 : 100,
                displayName: isPersonal ? "Personal caliente" : "Puky caliente"
            )
            return (
                response,
                try JSONEncoder().encode(
                    KycodeSessionsEnvelope(
                        ok: true,
                        now: Date().timeIntervalSince1970 * 1_000,
                        exportedAt: nil,
                        items: [item]
                    )
                )
            )
        }

        let oldForceInternet = ProcessInfo.processInfo.environment["KYCODE_UI_TEST_FORCE_INTERNET"]
        setenv("KYCODE_UI_TEST_FORCE_INTERNET", "1", 1)
        defer {
            if let oldForceInternet {
                setenv("KYCODE_UI_TEST_FORCE_INTERNET", oldForceInternet, 1)
            } else {
                unsetenv("KYCODE_UI_TEST_FORCE_INTERNET")
            }
        }

        let store = KycodeConnectionStore(
            urlSession: session,
            initialProfileIdOverride: "puky"
        )
        store.baseURLInput = "https://puky.mock"
        store.authTokenInput = "puky-test-token"
        await store.connect()
        XCTAssertEqual(store.sessions.first?.windowId, "puky-window")
        XCTAssertEqual(store.sessionSourceLabel(for: "puky-window"), "Puky")
        XCTAssertNil(store.sessionSourceLabel(for: "not-a-visible-window"))

        await store.selectProfile(id: "personal")
        XCTAssertEqual(store.sessions.first?.windowId, "personal-window")
        XCTAssertEqual(store.sessionSourceLabel(for: "personal-window"), "Mac personal")
        XCTAssertNil(store.sessionSourceLabel(for: "puky-window"))
        let pukyFetchCountBeforeReturn = sessionsFetchesByHost["puky.mock", default: 0]

        let startedAt = ProcessInfo.processInfo.systemUptime
        await store.selectProfile(id: "puky")
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt

        XCTAssertEqual(store.sessions.first?.windowId, "puky-window")
        XCTAssertEqual(store.sessionSourceLabel(for: "puky-window"), "Puky")
        XCTAssertNil(store.sessionSourceLabel(for: "personal-window"))
        XCTAssertEqual(
            sessionsFetchesByHost["puky.mock", default: 0],
            pukyFetchCountBeforeReturn,
            "Returning to a live target must not wait for another sessions bootstrap."
        )
        XCTAssertLessThan(elapsed, 0.25)
        store.disconnect()
    }

    func testCellularPathSkipsBonjourAndUsesInternetSizedTimeouts() {
        XCTAssertFalse(
            KycodeConnectionTransportPolicy.shouldAttemptBonjour(localIPv4Prefix: nil)
        )
        XCTAssertFalse(
            KycodeConnectionTransportPolicy.shouldAttemptBonjour(
                localIPv4Prefix: "10.42.0",
                forceInternet: true
            )
        )
        XCTAssertTrue(
            KycodeConnectionTransportPolicy.shouldAttemptBonjour(localIPv4Prefix: "10.42.0")
        )
        XCTAssertEqual(
            KycodeConnectionTransportPolicy.requestTimeout(
                forBaseURL: "https://relay.example.com/fermin-code-puky",
                localTimeout: 1.8,
                internetTimeout: 12
            ),
            12
        )
        XCTAssertEqual(
            KycodeConnectionTransportPolicy.requestTimeout(
                forBaseURL: "https://relay.example.com/legacy-hub",
                localTimeout: 1.8,
                internetTimeout: 12
            ),
            12
        )
        XCTAssertEqual(
            KycodeConnectionTransportPolicy.requestTimeout(
                forBaseURL: "http://10.42.0.63:8792",
                localTimeout: 1.8,
                internetTimeout: 12
            ),
            1.8
        )
    }

    func testPersonalBootstrapUsesOnlyCanonicalRemoteWithoutBonjourFallback() {
        for profileMode in [KycodeConnectionProfileMode.personal, .ferminCode] {
            for canUseBonjour in [false, true] {
                let attempts = KycodeConnectionTransportPolicy.bootstrapAttemptOrder(
                    profileMode: profileMode,
                    canUseBonjour: canUseBonjour
                )

                XCTAssertEqual(attempts, [.remote])
                XCTAssertFalse(attempts.contains(.preferred))
                XCTAssertFalse(attempts.contains(.cachedBonjour))
                XCTAssertFalse(attempts.contains(.bonjourDiscovery))
                XCTAssertTrue(attempts.dropFirst().isEmpty)
            }
        }
    }

    func testBootstrapOrderingRemainsStableForLegacyAndOtherProfiles() {
        XCTAssertEqual(
            KycodeConnectionTransportPolicy.bootstrapAttemptOrder(
                profileMode: .bonjourOnly,
                canUseBonjour: true
            ),
            [.preferred, .cachedBonjour, .bonjourDiscovery, .remote]
        )
        XCTAssertEqual(
            KycodeConnectionTransportPolicy.bootstrapAttemptOrder(
                profileMode: .remoteHub,
                canUseBonjour: true
            ),
            [.preferred, .remote]
        )
        XCTAssertEqual(
            KycodeConnectionTransportPolicy.bootstrapAttemptOrder(
                profileMode: .remoteFirst,
                canUseBonjour: true
            ),
            [.preferred, .remote, .cachedBonjour, .bonjourDiscovery]
        )
        XCTAssertEqual(
            KycodeConnectionTransportPolicy.bootstrapAttemptOrder(
                profileMode: .all,
                canUseBonjour: true
            ),
            [.preferred, .remote, .bonjourDiscovery]
        )
        for mode in [
            KycodeConnectionProfileMode.bonjourOnly,
            .remoteHub,
            .remoteFirst,
            .all,
        ] {
            XCTAssertEqual(
                KycodeConnectionTransportPolicy.bootstrapAttemptOrder(
                    profileMode: mode,
                    canUseBonjour: false
                ),
                [.preferred, .remote]
            )
        }
    }

    func testCredentialMigrationNeverUsesLANSidecarTokenForRemotePersonalMac() {
        XCTAssertNil(
            KycodeConnectionCredentialMigrationPolicy.personalRemoteToken(
                current: "lan-sidecar-token",
                legacyRemoteHub: nil,
                legacyLAN: "lan-sidecar-token"
            )
        )
        XCTAssertEqual(
            KycodeConnectionCredentialMigrationPolicy.personalRemoteToken(
                current: "lan-sidecar-token",
                legacyRemoteHub: "sync-hub-token",
                legacyLAN: "lan-sidecar-token"
            ),
            "sync-hub-token"
        )
        XCTAssertEqual(
            KycodeConnectionCredentialMigrationPolicy.personalRemoteToken(
                current: "new-manual-sync-token",
                legacyRemoteHub: "old-sync-token",
                legacyLAN: "lan-sidecar-token"
            ),
            "new-manual-sync-token"
        )
        XCTAssertNil(
            KycodeConnectionCredentialMigrationPolicy.genericTokenDestination(
                storedBaseURL: "http://10.42.0.63:8792",
                legacySelectedProfileId: "this-mac"
            )
        )
        XCTAssertEqual(
            KycodeConnectionCredentialMigrationPolicy.genericTokenDestination(
                storedBaseURL: "https://relay.example.com/legacy-hub",
                legacySelectedProfileId: "remote-hub"
            ),
            "personal"
        )
        XCTAssertEqual(
            KycodeConnectionCredentialMigrationPolicy.genericTokenDestination(
                storedBaseURL: "https://relay.example.com/fermin-code",
                legacySelectedProfileId: nil
            ),
            "personal"
        )
        XCTAssertEqual(
            KycodeConnectionCredentialMigrationPolicy.genericTokenDestination(
                storedBaseURL: "https://desktop.example.com",
                legacySelectedProfileId: "puky"
            ),
            "puky"
        )
    }

    func testCodexModelControlIgnoresStaleGenericCapabilityMetadata() {
        XCTAssertTrue(
            RuntimeModelControlPolicy.isAvailable(
                engine: .codex,
                advertisedFeatureControl: nil,
                unsupportedReason: nil
            )
        )
        XCTAssertTrue(
            RuntimeModelControlPolicy.isAvailable(
                engine: .codex,
                advertisedFeatureControl: false,
                unsupportedReason: "stale-capability-metadata"
            )
        )
        XCTAssertFalse(
            RuntimeModelControlPolicy.isAvailable(
                engine: .claude,
                advertisedFeatureControl: true,
                unsupportedReason: nil
            )
        )
    }

    @MainActor
    private func exerciseLateSendAfterProfileHandoff(
        personalPostFails: Bool
    ) async throws {
        let defaults = UserDefaults.standard
        let previousProfiles = defaults.data(forKey: profilesKey)
        let previousSelectedProfile = defaults.string(forKey: selectedProfileKey)
        let previousPersonalToken = KycodeKeychain.loadAuthToken(profileId: "personal")
        let previousPukyToken = KycodeKeychain.loadAuthToken(profileId: "puky")
        let previousForceInternet = ProcessInfo.processInfo.environment["KYCODE_UI_TEST_FORCE_INTERNET"]
        defaults.removeObject(forKey: profilesKey)
        defaults.set("personal", forKey: selectedProfileKey)
        KycodeKeychain.saveAuthToken("personal-send-owner-token", profileId: "personal")
        KycodeKeychain.saveAuthToken("puky-send-owner-token", profileId: "puky")
        setenv("KYCODE_UI_TEST_FORCE_INTERNET", "1", 1)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KycodeDeferredSendURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let personalPostStarted = expectation(
            description: personalPostFails
                ? "Personal failing send started"
                : "Personal successful send started"
        )
        let personalPostGate = KycodeDeferredRequestGate()
        let now = Date().timeIntervalSince1970 * 1_000
        let personalRevision = now
        let pukyRevision = now + 1
        var messagePostRoutes: [String] = []

        KycodeDeferredSendURLProtocol.handler = { [self] requestProtocol, request in
            do {
                let url = try XCTUnwrap(request.url)
                let isPersonal = url.path.hasPrefix("/fermin-code/")
                let source = isPersonal ? "PERSONAL" : "PUKY"
                let revision = isPersonal ? personalRevision : pukyRevision
                let message = KycodeMessage(
                    id: "\(source.lowercased())-owner-message",
                    role: "assistant",
                    type: "text",
                    content: "\(source)_CURRENT",
                    originalPrompt: nil,
                    transformedPrompt: nil,
                    improvedPrompt: nil,
                    timestamp: revision,
                    status: "completed",
                    imageAttachments: nil
                )
                let summary = makeSummary(
                    windowId: "shared-window",
                    updatedAt: revision,
                    displayName: "\(source) send owner",
                    messages: [message]
                )

                if request.httpMethod == "GET", url.path.hasSuffix("/api/mobile/stream") {
                    return
                }
                if request.httpMethod == "GET", url.path.hasSuffix("/api/mobile/sessions") {
                    requestProtocol.succeed(
                        data: try JSONEncoder().encode(
                            KycodeSessionsEnvelope(
                                ok: true,
                                now: revision,
                                exportedAt: nil,
                                items: [summary]
                            )
                        )
                    )
                    return
                }
                if request.httpMethod == "GET",
                   url.path.hasSuffix("/api/mobile/sessions/shared-window") {
                    requestProtocol.succeed(
                        data: try JSONEncoder().encode(
                            KycodeSessionDetailEnvelope(ok: true, now: revision, item: summary)
                        )
                    )
                    return
                }
                if request.httpMethod == "POST", url.path.hasSuffix("/message") {
                    messagePostRoutes.append(isPersonal ? "personal" : "puky")
                    guard isPersonal else {
                        requestProtocol.fail(with: URLError(.badURL))
                        return
                    }
                    personalPostGate.hold(requestProtocol)
                    personalPostStarted.fulfill()
                    return
                }
                if request.httpMethod == "GET",
                   url.path.hasSuffix("/api/mobile/preferences/prompt-improver") {
                    requestProtocol.succeed(
                        data: Data(
                            #"{"ok":true,"preference":{"version":1,"variant":"standard","updatedAt":"2026-08-17T12:00:00.000Z"},"variants":["standard","motivational"]}"#.utf8
                        )
                    )
                    return
                }
                requestProtocol.fail(with: URLError(.badURL))
            } catch {
                requestProtocol.fail(with: error)
            }
        }

        let store = KycodeConnectionStore(
            urlSession: session,
            initialProfileIdOverride: "personal",
            messageReconciliationSleep: { _ in await Task.yield() }
        )
        let previousVoiceDraft = store.currentVoiceDraft
        var testVoiceDrafts: [VoiceDraft] = []
        let personalAudioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fermin-send-owner-personal-\(UUID().uuidString).wav")
        let pukyAudioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fermin-send-owner-puky-\(UUID().uuidString).wav")
        defer {
            personalPostGate.fail(with: URLError(.cancelled))
            for draft in testVoiceDrafts {
                store.deleteVoiceDraft(draft)
            }
            if let previousVoiceDraft {
                store.persistVoiceDraft(previousVoiceDraft)
            }
            try? FileManager.default.removeItem(at: personalAudioURL)
            try? FileManager.default.removeItem(at: pukyAudioURL)
            store.disconnect()
            KycodeDeferredSendURLProtocol.handler = nil
            session.invalidateAndCancel()
            if let previousProfiles {
                defaults.set(previousProfiles, forKey: profilesKey)
            } else {
                defaults.removeObject(forKey: profilesKey)
            }
            if let previousSelectedProfile {
                defaults.set(previousSelectedProfile, forKey: selectedProfileKey)
            } else {
                defaults.removeObject(forKey: selectedProfileKey)
            }
            if let previousPersonalToken {
                KycodeKeychain.saveAuthToken(previousPersonalToken, profileId: "personal")
            } else {
                KycodeKeychain.deleteAuthToken(profileId: "personal")
            }
            if let previousPukyToken {
                KycodeKeychain.saveAuthToken(previousPukyToken, profileId: "puky")
            } else {
                KycodeKeychain.deleteAuthToken(profileId: "puky")
            }
            if let previousForceInternet {
                setenv("KYCODE_UI_TEST_FORCE_INTERNET", previousForceInternet, 1)
            } else {
                unsetenv("KYCODE_UI_TEST_FORCE_INTERNET")
            }
        }

        try Data("personal-audio".utf8).write(to: personalAudioURL, options: .atomic)
        try Data("puky-audio".utf8).write(to: pukyAudioURL, options: .atomic)

        await store.retryAutoConnect()
        await store.refreshDetail(windowId: "shared-window")
        XCTAssertEqual(
            store.detail(for: "shared-window")?.sessionId,
            "session-shared-window-\(Int(personalRevision))"
        )
        let personalJob = store.beginVoiceTranscription(
            windowId: "shared-window",
            duration: 2
        )
        let personalRoute = try XCTUnwrap(personalJob.owner?.route)
        let personalDraft = VoiceDraft(
            id: "send-owner-personal-\(UUID().uuidString)",
            windowId: "shared-window",
            filePath: personalAudioURL.path,
            duration: 2,
            createdAt: Date(),
            transcriptStatus: .success,
            transcriptText: "MENSAJE_PERSONAL",
            sendStatus: .idle,
            errorMessage: nil,
            isolationReport: nil,
            routeIdentity: personalRoute
        )
        testVoiceDrafts.append(personalDraft)
        store.persistVoiceDraft(personalDraft)

        let personalSend = Task { @MainActor in
            await store.sendMessage(
                windowId: "shared-window",
                text: "MENSAJE_PERSONAL"
            )
        }
        await fulfillment(of: [personalPostStarted], timeout: 2)

        await store.selectProfile(id: "puky")
        await store.refreshDetail(windowId: "shared-window")
        for _ in 0..<100 where store.detailLoadState(for: "shared-window") != .loaded {
            await Task.yield()
        }
        XCTAssertEqual(store.selectedProfileId, "puky")
        XCTAssertEqual(store.detailLoadState(for: "shared-window"), .loaded)
        XCTAssertEqual(
            store.detail(for: "shared-window")?.sessionId,
            "session-shared-window-\(Int(pukyRevision))"
        )
        let pukyJob = store.beginVoiceTranscription(
            windowId: "shared-window",
            duration: 3
        )
        let pukyRoute = try XCTUnwrap(pukyJob.owner?.route)
        let pukyDraft = VoiceDraft(
            id: "send-owner-puky-\(UUID().uuidString)",
            windowId: "shared-window",
            filePath: pukyAudioURL.path,
            duration: 3,
            createdAt: Date(),
            transcriptStatus: .success,
            transcriptText: "BORRADOR_PUKY",
            sendStatus: .idle,
            errorMessage: "BORRADOR_PUKY_SENTINEL",
            isolationReport: nil,
            routeIdentity: pukyRoute
        )
        testVoiceDrafts.append(pukyDraft)
        store.persistVoiceDraft(pukyDraft)
        store.errorMessage = "PUKY_ERROR_SENTINEL"

        if personalPostFails {
            personalPostGate.fail(with: URLError(.timedOut))
        } else {
            personalPostGate.succeed(
                data: Data(
                    """
                    {"ok":true,"commandId":"send-owner-personal","commandState":"completed","inserted":true,"durable":true,"queuedAt":\(personalRevision)}
                    """.utf8
                )
            )
        }
        let result = await personalSend.value

        XCTAssertEqual(result.sent, !personalPostFails)
        XCTAssertFalse(result.shouldApplyToCurrentComposer)
        XCTAssertNil(result.errorMessage)
        XCTAssertEqual(messagePostRoutes, ["personal"])
        XCTAssertEqual(store.selectedProfileId, "puky")
        XCTAssertEqual(
            store.detail(for: "shared-window")?.sessionId,
            "session-shared-window-\(Int(pukyRevision))"
        )
        XCTAssertEqual(store.errorMessage, "PUKY_ERROR_SENTINEL")
        XCTAssertEqual(store.currentVoiceDraft, pukyDraft)
        XCTAssertEqual(try Data(contentsOf: pukyAudioURL), Data("puky-audio".utf8))
    }

    @MainActor
    private func waitForPromptImproverVariant(
        _ variant: KycodePromptImproverVariant,
        in store: KycodeConnectionStore
    ) async {
        for _ in 0..<1_000 {
            if store.promptImproverVariantSelection == variant,
               store.promptImproverVariantSyncState == .synchronized,
               !store.isRefreshingPromptImproverVariant {
                return
            }
            await Task.yield()
        }
    }

    private func makeSummary(
        windowId: String,
        updatedAt: Double,
        displayName: String,
        messages: [KycodeMessage]? = nil,
        features: KycodeSessionFeatures? = nil
    ) -> KycodeSessionSummary {
        KycodeSessionSummary(
            windowId: windowId,
            sessionId: "session-\(windowId)-\(Int(updatedAt))",
            engine: "codex",
            model: "gpt-5.6-sol",
            reasoningEffort: "low",
            providerSessionId: nil,
            providerSessionPath: nil,
            projectKey: "project",
            projectPath: "/tmp/project",
            projectName: "Proyecto",
            windowName: displayName,
            displayName: displayName,
            sidecarMode: "mobile",
            sidecarUrl: nil,
            activityStatus: "ready",
            runtimeStatus: "READY",
            runtimeStatusDetail: nil,
            features: features,
            messageCount: 0,
            updatedAt: updatedAt,
            createdAt: nil,
            rawPrompt: nil,
            originalPrompt: nil,
            improvedPrompt: nil,
            lastMessagePreview: nil,
            isMinimized: false,
            canSend: true,
            canControlFeatures: false,
            unsupportedReason: "stale-capability-metadata",
            messages: messages
        )
    }
}

final class SessionDeletionTests: XCTestCase {
    private let cacheKey = "kycode.mobile.cachedSessions.v1"
    private let profilesKey = "kycode.mobile.connectionProfiles"
    private let selectedProfileKey = "kycode.mobile.selectedProfileId"
    private let baseURLKey = "kycode.mobile.baseURL"
    private let authTokenKey = "kycode.mobile.authToken"
    private var previousProfiles: Data?
    private var previousSelectedProfile: String?
    private var previousBaseURL: String?
    private var previousAuthToken: String?

    override func setUp() {
        super.setUp()
        previousProfiles = UserDefaults.standard.data(forKey: profilesKey)
        previousSelectedProfile = UserDefaults.standard.string(forKey: selectedProfileKey)
        previousBaseURL = UserDefaults.standard.string(forKey: baseURLKey)
        previousAuthToken = UserDefaults.standard.string(forKey: authTokenKey)
        UserDefaults.standard.removeObject(forKey: profilesKey)
        UserDefaults.standard.set("puky", forKey: selectedProfileKey)
        UserDefaults.standard.removeObject(forKey: cacheKey)
    }

    override func tearDown() {
        KycodeMockURLProtocol.handler = nil
        UserDefaults.standard.removeObject(forKey: cacheKey)
        if let previousProfiles {
            UserDefaults.standard.set(previousProfiles, forKey: profilesKey)
        } else {
            UserDefaults.standard.removeObject(forKey: profilesKey)
        }
        if let previousSelectedProfile {
            UserDefaults.standard.set(previousSelectedProfile, forKey: selectedProfileKey)
        } else {
            UserDefaults.standard.removeObject(forKey: selectedProfileKey)
        }
        if let previousBaseURL {
            UserDefaults.standard.set(previousBaseURL, forKey: baseURLKey)
        } else {
            UserDefaults.standard.removeObject(forKey: baseURLKey)
        }
        if let previousAuthToken {
            UserDefaults.standard.set(previousAuthToken, forKey: authTokenKey)
        } else {
            UserDefaults.standard.removeObject(forKey: authTokenKey)
        }
        super.tearDown()
    }

    @MainActor
    func testDeleteWaitsForDurableRemovalAndStaysAbsentAfterReload() async throws {
        let summary = makeSummary()
        let sessionData = try JSONEncoder().encode(
            KycodeSessionsEnvelope(
                ok: true,
                now: Date().timeIntervalSince1970 * 1_000,
                exportedAt: nil,
                items: [summary]
            )
        )
        let emptySessionData = try JSONEncoder().encode(
            KycodeSessionsEnvelope(
                ok: true,
                now: Date().timeIntervalSince1970 * 1_000,
                exportedAt: nil,
                items: []
            )
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KycodeMockURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        var observedDeleteRequest: URLRequest?
        var deleteAccepted = false

        KycodeMockURLProtocol.handler = { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            if request.httpMethod == "DELETE" {
                observedDeleteRequest = request
                deleteAccepted = true
                return (
                    response,
                    Data(
                        """
                        {"ok":true,"commandId":"delete-1","commandState":"accepted","inserted":true,"durable":true,"queuedAt":1,"windowId":"delete-window"}
                        """.utf8
                    )
                )
            }
            if request.url?.path == "/api/mobile/commands/delete-1" {
                return (
                    response,
                    Data(
                        """
                        {"ok":true,"commandId":"delete-1","commandState":"completed","updatedAt":2}
                        """.utf8
                    )
                )
            }
            return (response, deleteAccepted ? emptySessionData : sessionData)
        }

        let store = KycodeConnectionStore(
            urlSession: urlSession,
            initialProfileIdOverride: "puky"
        )
        defer { store.disconnect() }
        store.baseURLInput = "https://mock.kycode.test"
        store.authTokenInput = "test-token"
        await store.connect()
        XCTAssertEqual(store.sessions.map(\.windowId), ["delete-window"])

        let deleted = await store.deleteSession(windowId: "delete-window")
        XCTAssertTrue(deleted)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertNil(store.detail(for: "delete-window"))

        await store.refreshSessionsNow()
        XCTAssertTrue(
            store.sessions.isEmpty,
            "La sesión borrada no debe reaparecer después de recargar el estado autoritativo"
        )
        XCTAssertEqual(observedDeleteRequest?.httpMethod, "DELETE")
        XCTAssertEqual(
            observedDeleteRequest?.url?.path,
            "/api/mobile/sessions/delete-window/permanent"
        )
        XCTAssertEqual(
            observedDeleteRequest?.value(forHTTPHeaderField: "Authorization"),
            "Bearer test-token"
        )
    }

    @MainActor
    func testDeleteRollsBackWhenDurableCommandFailsAfterAcceptance() async throws {
        let summary = makeSummary()
        let sessionData = try JSONEncoder().encode(
            KycodeSessionsEnvelope(
                ok: true,
                now: Date().timeIntervalSince1970 * 1_000,
                exportedAt: nil,
                items: [summary]
            )
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KycodeMockURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)

        KycodeMockURLProtocol.handler = { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            if request.httpMethod == "DELETE" {
                return (
                    response,
                    Data(
                        #"{"ok":true,"commandId":"delete-failed","commandState":"accepted","inserted":true,"durable":true,"queuedAt":1,"windowId":"delete-window"}"#.utf8
                    )
                )
            }
            if request.url?.path == "/api/mobile/commands/delete-failed" {
                return (
                    response,
                    Data(
                        #"{"ok":false,"commandId":"delete-failed","commandState":"unknown","updatedAt":2,"error":"thread/delete failed"}"#.utf8
                    )
                )
            }
            return (response, sessionData)
        }

        let store = KycodeConnectionStore(urlSession: urlSession, initialProfileIdOverride: "puky")
        defer { store.disconnect() }
        store.baseURLInput = "https://mock.kycode.test"
        store.authTokenInput = "test-token"
        await store.connect()

        let deleted = await store.deleteSession(windowId: "delete-window")

        XCTAssertTrue(deleted, "The return value confirms acceptance, not completion.")
        store.applyDurableCommandStateChanged(KycodeCommandStateChangedEvent(
            commandId: "delete-failed", state: .unknown, error: "thread/delete failed"
        ))
        await store.refreshSessionsNow()
        XCTAssertEqual(store.sessions.map(\.windowId), ["delete-window"])
        XCTAssertEqual(store.detail(for: "delete-window")?.displayName, "QA borrado")
        XCTAssertEqual(store.errorMessage, "No se pudo archivar la sesión. thread/delete failed")
        store.dismissError()
        XCTAssertNil(store.errorMessage)
    }

    @MainActor
    func testMinimizeAppliesDurableEventAndSurvivesReload() async throws {
        let summary = makeSummary()
        let activeSessionData = try JSONEncoder().encode(
            KycodeSessionsEnvelope(
                ok: true,
                now: Date().timeIntervalSince1970 * 1_000,
                exportedAt: nil,
                items: [summary]
            )
        )
        let minimizedSessionData = try JSONEncoder().encode(
            KycodeSessionsEnvelope(
                ok: true,
                now: Date().timeIntervalSince1970 * 1_000,
                exportedAt: nil,
                items: [makeSummary(minimized: true)]
            )
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KycodeMockURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        var minimizeAccepted = false
        var observedMinimizeRequest: URLRequest?
        var observedCommandStatus = false

        KycodeMockURLProtocol.handler = { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            if request.url?.path == "/api/mobile/sessions/delete-window/minimize" {
                observedMinimizeRequest = request
                minimizeAccepted = true
                return (
                    response,
                    Data(
                        #"{"ok":true,"commandId":"minimize-1","commandState":"accepted","inserted":true,"durable":true,"queuedAt":1,"windowId":"delete-window","minimized":true}"#.utf8
                    )
                )
            }
            if request.url?.path == "/api/mobile/commands/minimize-1" {
                observedCommandStatus = true
                return (
                    response,
                    Data(
                        #"{"ok":true,"commandId":"minimize-1","commandState":"completed","updatedAt":2}"#.utf8
                    )
                )
            }
            return (response, minimizeAccepted ? minimizedSessionData : activeSessionData)
        }

        let store = KycodeConnectionStore(urlSession: urlSession, initialProfileIdOverride: "puky")
        defer { store.disconnect() }
        store.baseURLInput = "https://mock.kycode.test"
        store.authTokenInput = "test-token"
        await store.connect()

        let minimized = await store.setSessionMinimized(windowId: "delete-window", minimized: true)

        XCTAssertTrue(minimized)
        store.applyDurableCommandStateChanged(KycodeCommandStateChangedEvent(
            commandId: "minimize-1", state: .completed, error: nil
        ))
        XCTAssertFalse(observedCommandStatus, "Terminal events do not require status polling.")
        XCTAssertEqual(observedMinimizeRequest?.httpMethod, "POST")
        XCTAssertTrue(store.sessions.first?.minimized == true)
        await store.refreshSessionsNow()
        XCTAssertTrue(
            store.sessions.first?.minimized == true,
            "La sesión minimizada no debe reaparecer como activa después de recargar"
        )
    }

    @MainActor
    func testMinimizeReconcilesSnapshotWithoutCommandStatusPolling() async throws {
        let activeSessionData = try JSONEncoder().encode(
            KycodeSessionsEnvelope(
                ok: true,
                now: Date().timeIntervalSince1970 * 1_000,
                exportedAt: nil,
                items: [makeSummary()]
            )
        )
        let minimizedSessionData = try JSONEncoder().encode(
            KycodeSessionsEnvelope(
                ok: true,
                now: Date().timeIntervalSince1970 * 1_000,
                exportedAt: nil,
                items: [makeSummary(minimized: true)]
            )
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KycodeMockURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        var minimizeAccepted = false
        var observedLegacyStatusRequest = false

        KycodeMockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            if request.url?.path == "/api/mobile/sessions/delete-window/minimize" {
                minimizeAccepted = true
                return (
                    try XCTUnwrap(HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )),
                    Data(
                        #"{"ok":true,"commandId":"legacy-minimize","commandState":"accepted","inserted":true,"durable":true,"queuedAt":1,"windowId":"delete-window","minimized":true}"#.utf8
                    )
                )
            }
            if request.url?.path == "/api/mobile/commands/legacy-minimize" {
                observedLegacyStatusRequest = true
                return (
                    try XCTUnwrap(HTTPURLResponse(
                        url: url,
                        statusCode: 404,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )),
                    Data(#"{"ok":false,"error":"not found"}"#.utf8)
                )
            }
            return (
                try XCTUnwrap(HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )),
                minimizeAccepted ? minimizedSessionData : activeSessionData
            )
        }

        let store = KycodeConnectionStore(urlSession: urlSession, initialProfileIdOverride: "puky")
        defer { store.disconnect() }
        store.baseURLInput = "https://mock.kycode.test"
        store.authTokenInput = "test-token"
        await store.connect()

        let minimized = await store.setSessionMinimized(windowId: "delete-window", minimized: true)

        XCTAssertTrue(minimized)
        await store.refreshSessionsNow()
        XCTAssertFalse(observedLegacyStatusRequest)
        XCTAssertTrue(store.sessions.first?.minimized == true)
    }

    @MainActor
    func testMinimizeRollsBackWhenDurableCommandFailsAfterAcceptance() async throws {
        let summary = makeSummary()
        let sessionData = try JSONEncoder().encode(
            KycodeSessionsEnvelope(
                ok: true,
                now: Date().timeIntervalSince1970 * 1_000,
                exportedAt: nil,
                items: [summary]
            )
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KycodeMockURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)

        KycodeMockURLProtocol.handler = { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            if request.url?.path == "/api/mobile/sessions/delete-window/minimize" {
                return (
                    response,
                    Data(
                        #"{"ok":true,"commandId":"minimize-failed","commandState":"accepted","inserted":true,"durable":true,"queuedAt":1,"windowId":"delete-window","minimized":true}"#.utf8
                    )
                )
            }
            if request.url?.path == "/api/mobile/commands/minimize-failed" {
                return (
                    response,
                    Data(
                        #"{"ok":false,"commandId":"minimize-failed","commandState":"failed","updatedAt":2,"error":"thread/minimize failed"}"#.utf8
                    )
                )
            }
            return (response, sessionData)
        }

        let store = KycodeConnectionStore(urlSession: urlSession, initialProfileIdOverride: "puky")
        defer { store.disconnect() }
        store.baseURLInput = "https://mock.kycode.test"
        store.authTokenInput = "test-token"
        await store.connect()

        let minimized = await store.setSessionMinimized(windowId: "delete-window", minimized: true)

        XCTAssertTrue(minimized, "The optimistic change is pending after acceptance.")
        store.applyDurableCommandStateChanged(KycodeCommandStateChangedEvent(
            commandId: "minimize-failed", state: .failed, error: "thread/minimize failed"
        ))
        await store.refreshSessionsNow()
        XCTAssertFalse(store.sessions.first?.minimized == true)
        XCTAssertEqual(store.errorMessage, "No se pudo cambiar la visibilidad de la sesión. thread/minimize failed")
        store.dismissError()
        XCTAssertNil(store.errorMessage)
    }

    @MainActor
    func testCreateSubagentWaitsUntilItsFirstTurnStarted() async throws {
        let parent = makeSummary()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KycodeMockURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        var requestedSessionId: String?
        var observedCommandStatusRequest = false
        var postCreateSessionPollCount = 0
        let queuedAt = Date().timeIntervalSince1970 * 1_000

        KycodeMockURLProtocol.handler = { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            if request.url?.path.hasSuffix("/create-subagent") == true {
                let body = try XCTUnwrap(
                    try JSONSerialization.jsonObject(
                        with: kycodeRequestBodyData(request)
                    ) as? [String: Any]
                )
                let sessionId = try XCTUnwrap(body["sessionId"] as? String)
                requestedSessionId = sessionId
                return (
                    response,
                    Data(
                        """
                        {"ok":true,"commandId":"subagent-start","commandState":"accepted","inserted":true,"durable":true,"queuedAt":\(queuedAt),"sourceWindowId":"delete-window","sourceSessionId":"delete-session","projectPath":"/tmp/project","projectName":"Proyecto","sessionId":"\(sessionId)","engine":"codex"}
                        """.utf8
                    )
                )
            }
            if request.url?.path == "/api/mobile/commands/subagent-start" {
                observedCommandStatusRequest = true
                return (
                    response,
                    Data(
                        #"{"ok":true,"commandId":"subagent-start","commandState":"completed","updatedAt":2}"#.utf8
                    )
                )
            }

            let items: [KycodeSessionSummary]
            if let sessionId = requestedSessionId {
                postCreateSessionPollCount += 1
                let started = postCreateSessionPollCount >= 2
                items = [
                    KycodeSessionSummary(
                        windowId: "child-window",
                        sessionId: sessionId,
                        engine: "codex",
                        model: "gpt-5.6-sol",
                        reasoningEffort: "xhigh",
                        providerSessionId: "provider-child",
                        providerSessionPath: nil,
                        projectKey: "project",
                        projectPath: "/tmp/project",
                        projectName: "Proyecto",
                        windowName: "Subagente",
                        displayName: "Subagente",
                        sidecarMode: "mobile",
                        sidecarUrl: nil,
                        activityStatus: started ? "working" : "ready",
                        runtimeStatus: started ? "WORKING" : "WAITING",
                        runtimeStatusDetail: nil,
                        features: nil,
                        messageCount: started ? 1 : 0,
                        updatedAt: Date().timeIntervalSince1970 * 1_000,
                        createdAt: nil,
                        rawPrompt: nil,
                        originalPrompt: nil,
                        improvedPrompt: nil,
                        lastMessagePreview: started ? "Investigá el flujo" : nil,
                        isMinimized: false,
                        canSend: true,
                        canControlFeatures: true,
                        unsupportedReason: nil,
                        messages: nil,
                        pendingSubagent: KycodePendingSubagentDraft(
                            displayMessage: "Investigá el flujo",
                            parentNotificationPrompt: nil,
                            childMessageSentAt: started ? 2 : nil
                        )
                    ),
                    parent,
                ]
            } else {
                items = [parent]
            }
            return (
                response,
                try JSONEncoder().encode(
                    KycodeSessionsEnvelope(
                        ok: true,
                        now: Date().timeIntervalSince1970 * 1_000,
                        exportedAt: nil,
                        items: items
                    )
                )
            )
        }

        let store = KycodeConnectionStore(urlSession: urlSession, initialProfileIdOverride: "puky")
        defer { store.disconnect() }
        store.baseURLInput = "https://mock.kycode.test"
        store.authTokenInput = "test-token"
        await store.connect()

        let result = await store.createSubagent(
            windowId: "delete-window",
            text: "Investigá el flujo"
        )

        XCTAssertEqual(result?.windowId, "child-window")
        XCTAssertEqual(result?.status, "working")
        XCTAssertFalse(observedCommandStatusRequest, "The authoritative session confirms the first turn.")
        XCTAssertGreaterThanOrEqual(postCreateSessionPollCount, 2)
        XCTAssertEqual(
            store.sessions.first(where: { $0.windowId == "child-window" })?.messageCount,
            1
        )
        XCTAssertNotNil(
            store.sessions.first(where: { $0.windowId == "child-window" })?
                .pendingSubagent?.childMessageSentAt
        )
    }

    @MainActor
    func testDeleteFailureRollsSessionBackWithoutDataLoss() async throws {
        let summary = makeSummary()
        let sessionData = try JSONEncoder().encode(
            KycodeSessionsEnvelope(
                ok: true,
                now: Date().timeIntervalSince1970 * 1_000,
                exportedAt: nil,
                items: [summary]
            )
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KycodeMockURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)

        KycodeMockURLProtocol.handler = { request in
            let isDelete = request.httpMethod == "DELETE"
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: isDelete ? 404 : 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            return isDelete
                ? (response, Data(#"{"error":"not found"}"#.utf8))
                : (response, sessionData)
        }

        let store = KycodeConnectionStore(
            urlSession: urlSession,
            initialProfileIdOverride: "puky"
        )
        defer { store.disconnect() }
        store.baseURLInput = "https://mock.kycode.test"
        store.authTokenInput = "test-token"
        await store.connect()

        let deleted = await store.deleteSession(windowId: "delete-window")
        XCTAssertFalse(deleted)
        XCTAssertEqual(store.sessions.map(\.windowId), ["delete-window"])
        XCTAssertEqual(store.detail(for: "delete-window")?.displayName, "QA borrado")
        XCTAssertEqual(store.errorMessage, "not found")
    }

    func testCollaborationProjectMetadataKeepsSessionNameIndependent() throws {
        var summary = makeSummary()
        summary.collaborationProjectId = "collaboration-project:fermin"
        summary.collaborationProjectName = "fermin"
        summary.sessionName = "QA borrado"

        let decoded = try JSONDecoder().decode(
            KycodeSessionSummary.self,
            from: JSONEncoder().encode(summary)
        )

        XCTAssertEqual(decoded.collaborationProjectId, "collaboration-project:fermin")
        XCTAssertEqual(decoded.collaborationProjectDisplayName, "fermin")
        XCTAssertEqual(decoded.collaborationSessionName, "QA borrado")
        XCTAssertEqual(decoded.collaborationDisplayName, "fermin: QA borrado")
        XCTAssertEqual(decoded.projectPath, "/tmp/project", "La carpeta física debe permanecer independiente")
    }

    func testLegacyProjectPrefixStillDecodesIntoSeparateDisplayValues() throws {
        let base = makeSummary()
        let data = try JSONEncoder().encode(base)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object["windowName"] = "kycode: prompt improver fix"
        object["displayName"] = "kycode: prompt improver fix"
        object.removeValue(forKey: "collaborationProjectId")
        object.removeValue(forKey: "collaborationProjectName")
        object.removeValue(forKey: "sessionName")

        let decoded = try JSONDecoder().decode(
            KycodeSessionSummary.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(decoded.collaborationProjectDisplayName, "kycode")
        XCTAssertEqual(decoded.collaborationSessionName, "prompt improver fix")
    }

    @MainActor
    func testProjectSelectionLoadsCatalogAndSendsIdWithName() async throws {
        let summary = makeSummary()
        let sessionData = try JSONEncoder().encode(
            KycodeSessionsEnvelope(
                ok: true,
                now: Date().timeIntervalSince1970 * 1_000,
                exportedAt: nil,
                items: [summary]
            )
        )
        let project = KycodeCollaborationProject(
            id: "collaboration-project:fermin",
            name: "fermin",
            activeSessionCount: 1
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KycodeMockURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        var assignmentBody: [String: String]?

        KycodeMockURLProtocol.handler = { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            if request.url?.path == "/api/mobile/collaboration-projects" {
                return (
                    response,
                    Data(
                        """
                        {"ok":true,"now":1,"items":[{"id":"collaboration-project:fermin","name":"fermin","activeSessionCount":1}]}
                        """.utf8
                    )
                )
            }
            if request.url?.path == "/api/mobile/sessions/delete-window/collaboration-project" {
                assignmentBody = try JSONDecoder().decode(
                    [String: String].self,
                    from: try kycodeRequestBodyData(request)
                )
                return (
                    response,
                    Data(
                        """
                        {"ok":true,"commandId":"assign-1","commandState":"accepted","inserted":true,"durable":true,"queuedAt":1,"windowId":"delete-window","project":{"id":"collaboration-project:fermin","name":"fermin","activeSessionCount":1},"unchanged":false}
                        """.utf8
                    )
                )
            }
            return (response, sessionData)
        }

        let store = KycodeConnectionStore(
            urlSession: urlSession,
            initialProfileIdOverride: "puky"
        )
        defer { store.disconnect() }
        store.baseURLInput = "https://mock.kycode.test"
        store.authTokenInput = "test-token"
        await store.connect()

        let projects = await store.fetchCollaborationProjects(windowId: "delete-window")
        XCTAssertEqual(projects, [project])
        let assigned = await store.assignCollaborationProject(windowId: "delete-window", project: project)
        XCTAssertTrue(assigned)
        XCTAssertEqual(assignmentBody?["projectId"], project.id)
        XCTAssertEqual(assignmentBody?["projectName"], project.name)
        XCTAssertEqual(store.sessions.first?.collaborationDisplayName, "fermin: QA borrado")
    }

    @MainActor
    func testPromptImproverRetryTargetsExistingMessageWithoutResendingIt() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KycodeMockURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        var observedRequests: [URLRequest] = []
        let detailData = try JSONEncoder().encode(
            KycodeSessionDetailEnvelope(ok: true, now: 1, item: makeSummary())
        )

        KycodeMockURLProtocol.handler = { request in
            observedRequests.append(request)
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            if request.url?.path.hasSuffix("/retry-prompt-transform") == true {
                return (response, Data(#"{"ok":true,"messageId":"failed-message"}"#.utf8))
            }
            return (response, detailData)
        }
        defer {
            KycodeMockURLProtocol.handler = nil
            urlSession.invalidateAndCancel()
        }

        let store = KycodeConnectionStore(
            urlSession: urlSession,
            initialProfileIdOverride: "puky"
        )
        defer { store.disconnect() }
        store.baseURLInput = "https://mock.kycode.test"
        store.authTokenInput = "test-token"

        let result = await store.retryPromptImprover(
            windowId: "delete-window",
            messageId: "failed-message"
        )

        XCTAssertTrue(result.sent)
        let retryRequests = observedRequests.filter {
            $0.url?.path.hasSuffix("/retry-prompt-transform") == true
        }
        XCTAssertEqual(retryRequests.count, 1)
        XCTAssertEqual(
            retryRequests.first?.url?.path,
            "/api/mobile/sessions/delete-window/messages/failed-message/retry-prompt-transform"
        )
        XCTAssertEqual(
            retryRequests.first?.timeoutInterval,
            13 * 60,
            "iOS must allow both six-minute prompt stages plus transport cleanup."
        )
        XCTAssertFalse(observedRequests.contains(where: { $0.url?.path.hasSuffix("/message") == true }))
        let body = try JSONDecoder().decode(
            [String: String].self,
            from: try kycodeRequestBodyData(try XCTUnwrap(retryRequests.first))
        )
        XCTAssertEqual(body["messageId"], "failed-message")
    }

    @MainActor
    func testPromptImproverRetryReconcilesStaleErrorToProcessingAndResolvedWithoutSSE() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KycodeMockURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        var observedRequests: [URLRequest] = []
        var detailRequestCount = 0

        func promptMessage(
            status: String,
            output: String? = nil,
            errorReason: String? = nil
        ) -> KycodeMessage {
            KycodeMessage(
                id: "failed-message",
                role: "user",
                type: "user",
                content: "Prompt original",
                originalPrompt: "Prompt original",
                transformedPrompt: output,
                improvedPrompt: output,
                timestamp: 100,
                status: nil,
                imageAttachments: nil,
                transformStatus: status,
                transformErrorReason: errorReason,
                promptTransformNote: output == nil ? nil : "Mejorado"
            )
        }

        let detailResponses = try [
            makeSummary(
                updatedAt: 100,
                messages: [promptMessage(status: "error", errorReason: "old_failure")]
            ),
            makeSummary(
                updatedAt: 100,
                messages: [promptMessage(status: "error", errorReason: "old_failure")]
            ),
            makeSummary(
                updatedAt: 101,
                messages: [promptMessage(status: "processing")]
            ),
            makeSummary(
                updatedAt: 102,
                messages: [promptMessage(status: "done", output: "Prompt mejorado por Fermín")]
            ),
        ].map {
            try JSONEncoder().encode(KycodeSessionDetailEnvelope(ok: true, now: $0.updatedAt, item: $0))
        }

        KycodeMockURLProtocol.handler = { request in
            observedRequests.append(request)
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            if request.url?.path.hasSuffix("/retry-prompt-transform") == true {
                return (
                    response,
                    Data(
                        #"{"ok":true,"commandId":"cmd-retry-stale","commandState":"accepted","inserted":true,"durable":true,"queuedAt":100,"messageId":"failed-message"}"#.utf8
                    )
                )
            }
            if request.url?.path.hasSuffix("/delete-window") == true {
                let index = min(detailRequestCount, detailResponses.count - 1)
                detailRequestCount += 1
                return (response, detailResponses[index])
            }
            return (response, Data(#"{"ok":true,"now":1,"items":[]}"#.utf8))
        }
        defer {
            KycodeMockURLProtocol.handler = nil
            urlSession.invalidateAndCancel()
        }

        let store = KycodeConnectionStore(
            urlSession: urlSession,
            initialProfileIdOverride: "puky",
            messageReconciliationNow: { 10 },
            messageReconciliationSleep: { _ in await Task.yield() }
        )
        store.baseURLInput = "https://mock.kycode.test"
        store.authTokenInput = "test-token"

        await store.refreshDetail(windowId: "delete-window")
        XCTAssertEqual(
            store.detail(for: "delete-window")?.messages?.first?.transformStatus,
            "error"
        )

        let result = await store.retryPromptImprover(
            windowId: "delete-window",
            messageId: "failed-message"
        )
        XCTAssertEqual(result, .success)

        for _ in 0..<40 where
            store.detail(for: "delete-window")?.messages?.first?.transformedPrompt == nil {
            await Task.yield()
        }

        XCTAssertEqual(
            store.detail(for: "delete-window")?.messages?.first?.transformedPrompt,
            "Prompt mejorado por Fermín"
        )
        XCTAssertEqual(detailRequestCount, 4)
        let settledRequestCount = observedRequests.count
        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertEqual(observedRequests.count, settledRequestCount)
        XCTAssertEqual(
            observedRequests.filter {
                $0.url?.path.hasSuffix("/retry-prompt-transform") == true
            }.count,
            1
        )
        XCTAssertFalse(
            observedRequests.contains(where: {
                $0.url?.path.hasSuffix("/message") == true
            })
        )
    }

    @MainActor
    func testPromptImproverPendingTimeoutBecomesActionableAndLateOutputClearsIt() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KycodeMockURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        var observedRequests: [URLRequest] = []
        var detailRequestCount = 0
        var publishesLateResolution = false

        func promptMessage(status: String, output: String? = nil) -> KycodeMessage {
            KycodeMessage(
                id: "failed-message",
                role: "user",
                type: "user",
                content: "Prompt original",
                originalPrompt: "Prompt original",
                transformedPrompt: output,
                improvedPrompt: output,
                timestamp: 100,
                status: nil,
                imageAttachments: nil,
                transformStatus: status,
                transformErrorReason: status == "error" ? "old_failure" : nil,
                promptTransformNote: output == nil ? nil : "Mejorado"
            )
        }

        KycodeMockURLProtocol.handler = { request in
            observedRequests.append(request)
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            if request.url?.path.hasSuffix("/retry-prompt-transform") == true {
                return (
                    response,
                    Data(
                        #"{"ok":true,"commandId":"cmd-retry-timeout","commandState":"accepted","inserted":true,"durable":true,"queuedAt":100,"messageId":"failed-message"}"#.utf8
                    )
                )
            }
            if request.url?.path.hasSuffix("/delete-window") == true {
                detailRequestCount += 1
                let message: KycodeMessage
                if detailRequestCount == 1 {
                    message = promptMessage(status: "error")
                } else if publishesLateResolution {
                    message = promptMessage(
                        status: "done",
                        output: "Prompt mejorado tardío"
                    )
                } else {
                    message = promptMessage(status: "processing")
                }
                let item = self.makeSummary(
                    updatedAt: 100 + Double(detailRequestCount),
                    messages: [message]
                )
                return (
                    response,
                    try JSONEncoder().encode(
                        KycodeSessionDetailEnvelope(
                            ok: true,
                            now: item.updatedAt,
                            item: item
                        )
                    )
                )
            }
            return (response, Data(#"{"ok":true,"now":1,"items":[]}"#.utf8))
        }
        defer {
            KycodeMockURLProtocol.handler = nil
            urlSession.invalidateAndCancel()
        }

        let store = KycodeConnectionStore(
            urlSession: urlSession,
            initialProfileIdOverride: "puky",
            messageReconciliationNow: { 10 },
            messageReconciliationSleep: { _ in await Task.yield() }
        )
        store.baseURLInput = "https://mock.kycode.test"
        store.authTokenInput = "test-token"

        await store.refreshDetail(windowId: "delete-window")
        XCTAssertEqual(
            store.detail(for: "delete-window")?.messages?.first?.transformStatus,
            "error"
        )

        let retryResult = await store.retryPromptImprover(
            windowId: "delete-window",
            messageId: "failed-message"
        )
        XCTAssertEqual(retryResult, .success)

        for _ in 0..<200 where
            !store.promptTransformTimedOutMessageIds(windowId: "delete-window")
                .contains("failed-message") {
            await Task.yield()
        }

        XCTAssertEqual(
            store.promptTransformTimedOutMessageIds(windowId: "delete-window"),
            ["failed-message"]
        )
        XCTAssertEqual(detailRequestCount, 12)
        XCTAssertEqual(
            observedRequests.filter {
                $0.url?.path.hasSuffix("/retry-prompt-transform") == true
            }.count,
            1
        )

        let settledRequestCount = observedRequests.count
        for _ in 0..<30 {
            await Task.yield()
        }
        XCTAssertEqual(observedRequests.count, settledRequestCount)

        publishesLateResolution = true
        await store.refreshDetail(windowId: "delete-window")

        XCTAssertEqual(
            store.detail(for: "delete-window")?.messages?.first?.transformedPrompt,
            "Prompt mejorado tardío"
        )
        XCTAssertTrue(
            store.promptTransformTimedOutMessageIds(windowId: "delete-window").isEmpty
        )
        XCTAssertEqual(detailRequestCount, 13)
    }

    @MainActor
    func testPromptRetryIntentClearsOnTerminalDurableFailure() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KycodeMockURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        var detailRequestCount = 0
        let failedMessage = KycodeMessage(
            id: "failed-message",
            role: "user",
            type: "user",
            content: "Prompt original",
            originalPrompt: "Prompt original",
            transformedPrompt: nil,
            improvedPrompt: nil,
            timestamp: 100,
            status: nil,
            imageAttachments: nil,
            transformStatus: "error",
            transformErrorReason: "old_failure"
        )
        let staleDetailData = try JSONEncoder().encode(
            KycodeSessionDetailEnvelope(
                ok: true,
                now: 100,
                item: makeSummary(updatedAt: 100, messages: [failedMessage])
            )
        )

        KycodeMockURLProtocol.handler = { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            if request.url?.path.hasSuffix("/retry-prompt-transform") == true {
                return (
                    response,
                    Data(
                        #"{"ok":true,"commandId":"cmd-retry-failure","commandState":"accepted","inserted":true,"durable":true,"queuedAt":100,"messageId":"failed-message"}"#.utf8
                    )
                )
            }
            if request.url?.path.hasSuffix("/delete-window") == true {
                detailRequestCount += 1
                return (response, staleDetailData)
            }
            return (response, Data(#"{"ok":true,"now":1,"items":[]}"#.utf8))
        }
        defer {
            KycodeMockURLProtocol.handler = nil
            urlSession.invalidateAndCancel()
        }

        let store = KycodeConnectionStore(
            urlSession: urlSession,
            initialProfileIdOverride: "puky",
            messageReconciliationNow: { 10 },
            messageReconciliationSleep: { _ in await Task.yield() }
        )
        store.baseURLInput = "https://mock.kycode.test"
        store.authTokenInput = "test-token"

        await store.refreshDetail(windowId: "delete-window")
        let retryResult = await store.retryPromptImprover(
            windowId: "delete-window",
            messageId: "failed-message"
        )
        XCTAssertEqual(retryResult, .success)
        store.applyDurableCommandStateChanged(
            KycodeCommandStateChangedEvent(
                commandId: "cmd-retry-failure",
                state: .failed,
                error: "retry rejected"
            )
        )
        XCTAssertTrue(store.errorMessage?.contains("retry rejected") == true)
        for _ in 0..<30 {
            await Task.yield()
        }

        XCTAssertEqual(detailRequestCount, 3)
    }

    private func makeSummary(
        updatedAt: Double = Date().timeIntervalSince1970 * 1_000,
        messages: [KycodeMessage]? = nil,
        minimized: Bool = false
    ) -> KycodeSessionSummary {
        KycodeSessionSummary(
            windowId: "delete-window",
            sessionId: "delete-session",
            engine: "codex",
            model: "gpt-5.6-sol",
            reasoningEffort: "xhigh",
            providerSessionId: nil,
            providerSessionPath: nil,
            projectKey: "project",
            projectPath: "/tmp/project",
            projectName: "Proyecto",
            windowName: "QA borrado",
            displayName: "QA borrado",
            sidecarMode: "mobile",
            sidecarUrl: nil,
            activityStatus: "ready",
            runtimeStatus: "READY",
            runtimeStatusDetail: nil,
            features: nil,
            messageCount: 1,
            updatedAt: updatedAt,
            createdAt: nil,
            rawPrompt: nil,
            originalPrompt: nil,
            improvedPrompt: nil,
            lastMessagePreview: "Solo datos QA descartables",
            isMinimized: minimized,
            canSend: true,
            canControlFeatures: true,
            unsupportedReason: nil,
            messages: messages
        )
    }
}
