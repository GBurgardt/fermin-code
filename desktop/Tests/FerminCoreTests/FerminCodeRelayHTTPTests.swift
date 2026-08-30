import Foundation
import Testing
@testable import FerminCore

@Suite("Fermin Code relay HTTP")
struct FerminCodeRelayHTTPTests {
    private let token = "unit-test-relay-token-0000000000000001"

    @Test
    func bearerPrivateNoCacheRequestTargetsOnlySelectedSource() async throws {
        let response = FerminRelayTransportResponse(
            statusCode: 200,
            headers: ["content-type": "application/json"],
            body: Data("{\"ok\":true,\"now\":1720000000000,\"items\":[]}".utf8)
        )
        let transport = FerminCodeRelayMockHTTPTransport(response: response)
        let client = try FerminCodeRelayClient(
            source: .personal,
            token: token,
            transport: transport
        )

        _ = try await client.fetchSessions()
        let request = await transport.lastRequest()
        #expect(request?.url?.absoluteString ==
            "https://relay.example.com/fermin-code/api/mobile/sessions")
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
        #expect(request?.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        #expect(request?.value(forHTTPHeaderField: "Pragma") == "no-cache")
        #expect(request?.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(request?.url?.absoluteString.contains("fermin-code-puky") == false)
    }

    @Test
    func archiveUsesTheExplicitNonDestructiveEndpoint() async throws {
        let response = FerminRelayTransportResponse(
            statusCode: 200,
            body: Data(
                """
                {"ok":true,"commandId":"archive","commandState":"accepted","inserted":true,"durable":true,"queuedAt":1,"windowId":"window"}
                """.utf8
            )
        )
        let transport = FerminCodeRelayMockHTTPTransport(response: response)
        let client = try FerminCodeRelayClient(
            source: .puky,
            token: token,
            transport: transport
        )

        _ = try await client.archive(windowID: "window")

        let request = await transport.lastRequest()
        #expect(request?.httpMethod == "POST")
        #expect(request?.url?.absoluteString ==
            "https://relay.example.com/fermin-code-puky/api/mobile/sessions/window/archive")
    }

    @Test
    func permanentDeleteUsesOnlyTheExplicitDestructiveEndpoint() async throws {
        let response = FerminRelayTransportResponse(
            statusCode: 200,
            body: Data(
                """
                {"ok":true,"commandId":"delete","commandState":"accepted","inserted":true,"durable":true,"queuedAt":1,"windowId":"window"}
                """.utf8
            )
        )
        let transport = FerminCodeRelayMockHTTPTransport(response: response)
        let client = try FerminCodeRelayClient(
            source: .personal,
            token: token,
            transport: transport
        )

        _ = try await client.deletePermanently(windowID: "window")

        let request = await transport.lastRequest()
        #expect(request?.httpMethod == "DELETE")
        #expect(request?.url?.absoluteString ==
            "https://relay.example.com/fermin-code/api/mobile/sessions/window/permanent")
    }

    @Test
    func pinnedMutationUsesSharedDurableEndpointAndBooleanBody() async throws {
        let response = FerminRelayTransportResponse(
            statusCode: 200,
            body: Data(
                """
                {"ok":true,"commandId":"pin","commandState":"accepted","inserted":true,"durable":true,"queuedAt":1,"windowId":"window","pinned":false}
                """.utf8
            )
        )
        let transport = FerminCodeRelayMockHTTPTransport(response: response)
        let client = try FerminCodeRelayClient(
            source: .personal,
            token: token,
            transport: transport
        )

        _ = try await client.setPinned(windowID: "window", pinned: false)

        let request = await transport.lastRequest()
        #expect(request?.httpMethod == "PUT")
        #expect(request?.url?.absoluteString ==
            "https://relay.example.com/fermin-code/api/mobile/sessions/window/pinned")
        let body = try #require(request?.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Bool])
        #expect(json == ["pinned": false])
    }

    @Test
    func serverErrorsAreTypedAndBodiesAreBounded() async throws {
        let transport = FerminCodeRelayMockHTTPTransport(
            response: .init(
                statusCode: 409,
                body: Data("{\"code\":\"BUSY\",\"error\":\"try later\"}".utf8)
            )
        )
        let client = try FerminCodeRelayClient(
            source: .personal,
            token: token,
            transport: transport
        )
        do {
            _ = try await client.fetchSessions()
            Issue.record("HTTP failure decoded as success")
        } catch let error as FerminRelayHTTPError {
            #expect(error == .httpStatus(
                statusCode: 409,
                serverCode: "BUSY",
                message: "try later"
            ))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func oversizedRequestIsRejectedBeforeTransport() async throws {
        let transport = FerminCodeRelayMockHTTPTransport(
            response: .init(statusCode: 200, body: Data("{}".utf8))
        )
        let configuration = FerminRelayHTTPConfiguration(
            maximumJSONRequestBodyBytes: 32
        )
        let client = try FerminCodeRelayClient(
            source: .personal,
            token: token,
            transport: transport,
            configuration: configuration
        )
        do {
            _ = try await client.sendMessage(
                windowID: "window",
                request: .init(message: String(repeating: "x", count: 256))
            )
            Issue.record("Oversized body reached transport")
        } catch let error as FerminRelayHTTPError {
            guard case let .requestBodyTooLarge(actualBytes, maximumBytes) = error else {
                Issue.record("Unexpected HTTP error: \(error)")
                return
            }
            #expect(actualBytes > 32)
            #expect(maximumBytes == 32)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await transport.requestCount == 0)
    }

    @Test
    func rawAttachmentLimitIsCheckedBeforeMultipartAllocationOrTransport() async throws {
        let expectedMaximumBodyBytes = 20 * 1_048_576 + 128 * 1_024
        #expect(
            FerminRelayHTTPConfiguration().maximumUploadRequestBodyBytes
                == expectedMaximumBodyBytes
        )
        let transport = FerminCodeRelayMockHTTPTransport(
            response: .init(statusCode: 200, body: Data("{}".utf8))
        )
        let client = try FerminCodeRelayClient(
            source: .personal,
            token: token,
            transport: transport
        )
        let oversized = Data(
            repeating: 0xAB,
            count: FerminRelayHTTPConfiguration.maximumAttachmentBytes + 1
        )
        do {
            _ = try await client.uploadAttachment(
                windowID: "window",
                attachment: .init(
                    fileName: "image.png",
                    mimeType: "image/png",
                    data: oversized
                )
            )
            Issue.record("Oversized raw attachment reached multipart encoding")
        } catch let error as FerminRelayHTTPError {
            #expect(error == .requestBodyTooLarge(
                actualBytes: FerminRelayHTTPConfiguration.maximumAttachmentBytes + 1,
                maximumBytes: FerminRelayHTTPConfiguration.maximumAttachmentBytes
            ))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(await transport.requestCount == 0)
    }
}

actor FerminCodeRelayMockHTTPTransport: FerminRelayHTTPTransport {
    private let fixedResponse: FerminRelayTransportResponse
    private var requests: [URLRequest] = []

    init(response: FerminRelayTransportResponse) {
        fixedResponse = response
    }

    var requestCount: Int { requests.count }

    func response(
        for request: URLRequest,
        maximumBodyBytes: Int
    ) async throws -> FerminRelayTransportResponse {
        requests.append(request)
        guard fixedResponse.body.count <= maximumBodyBytes else {
            throw FerminRelayHTTPError.responseBodyTooLarge(maximumBytes: maximumBodyBytes)
        }
        return fixedResponse
    }

    func lastRequest() -> URLRequest? { requests.last }
}

actor FerminCodeRelayMockSSETransport: FerminRelaySSETransport {
    private let chunks: [Data]
    private var requests: [URLRequest] = []

    init(chunks: [Data]) {
        self.chunks = chunks
    }

    func openEventStream(for request: URLRequest) async throws -> FerminRelaySSEConnection {
        requests.append(request)
        let chunks = self.chunks
        return FerminRelaySSEConnection(
            statusCode: 200,
            headers: ["content-type": "text/event-stream"],
            chunks: AsyncThrowingStream { continuation in
                for chunk in chunks { continuation.yield(chunk) }
                continuation.finish()
            }
        )
    }

    func lastRequest() -> URLRequest? { requests.last }
}
