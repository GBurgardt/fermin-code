import Foundation
import Testing
@testable import FerminCore

@Suite("Fermin Code relay SSE")
struct FerminCodeRelaySSETests {
    @Test
    func productionDeliveryBufferIsStrictlyBounded() {
        let configuration = FerminRelayHTTPConfiguration()
        #expect(configuration.maximumBufferedSSEDeliveries == 16)
    }

    @Test
    func splitFramesMultilineDataAndReplayDedupeAreDeterministic() throws {
        var parser = FerminRelaySSEParser(maximumFrameBytes: 512, replayAfterEventID: 40)
        var events: [FerminRelaySSEEvent] = []
        for chunk in [
            "id: 40\nevent: stale\ndata: ignored\n\nid: 4",
            "1\nevent: note\ndata: first\ndata: second\n\nid: 41\nevent: duplicate\ndata: no\n\n",
            "id: 42\nevent: done\ndata: {\"ok\":true}\n\n",
        ] {
            events += try parser.feed(Data(chunk.utf8))
        }
        events += try parser.finish()

        #expect(events.map(\.id) == [41, 42])
        #expect(events[0].name == "note")
        #expect(events[0].dataString == "first\nsecond")
        #expect(events[1].name == "done")
    }

    @Test
    func cursorSetsLastEventIDAndNeverRegresses() throws {
        var cursor = FerminRelaySSECursor(lastEventID: 7)
        var request = URLRequest(url: URL(string: "https://example.test/events")!)
        cursor.applyLastEventID(to: &request)
        #expect(request.value(forHTTPHeaderField: "Last-Event-ID") == "7")
        try cursor.commit(eventID: 8)
        #expect(cursor.lastEventID == 8)

        do {
            try cursor.commit(eventID: 6)
            Issue.record("Cursor regression was accepted")
        } catch let error as FerminRelaySSEParserError {
            #expect(error == .cursorRegression(current: 8, candidate: 6))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func invalidNumericCursorAndOversizedFramesFailClosed() {
        var invalid = FerminRelaySSEParser(maximumFrameBytes: 128)
        do {
            _ = try invalid.feed(Data("id: opaque\ndata: x\n\n".utf8))
            Issue.record("Opaque event id was accepted")
        } catch let error as FerminRelaySSEParserError {
            #expect(error == .invalidEventID("opaque"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        var oversized = FerminRelaySSEParser(maximumFrameBytes: 8)
        do {
            _ = try oversized.feed(Data("data: 123456789".utf8))
            Issue.record("Oversized frame was accepted")
        } catch let error as FerminRelaySSEParserError {
            #expect(error == .frameTooLarge(maximumBytes: 8))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func defaultFrameLimitAcceptsMaximumAuthoritativeSnapshot() throws {
        #expect(FerminRelayHTTPConfiguration().maximumSSEFrameBytes == 5 * 1_048_576)
        var parser = FerminRelaySSEParser()
        let padding = String(repeating: "x", count: 4 * 1_048_576)
        let frame = Data(
            "event: snapshot\ndata: {\"ok\":true,\"cursor\":1,\"items\":[],\"padding\":\"\(padding)\"}\n\n".utf8
        )
        let events = try parser.feed(frame)
        #expect(events.count == 1)
        #expect(events[0].name == "snapshot")
    }

    @Test
    func snapshotRollbackResetsParserAndConsumerCursorBeforeSameChunkReplay() async throws {
        let http = FerminCodeRelayMockHTTPTransport(
            response: .init(statusCode: 200, body: Data("{}".utf8))
        )
        let chunk = Data(
            """
            event: snapshot
            data: {"ok":true,"cursor":3,"items":[]}

            id: 4
            event: command_state_changed
            data: {"commandId":"after-reset","state":"completed"}

            """.utf8
        )
        let sse = FerminCodeRelayMockSSETransport(chunks: [chunk])
        let client = try FerminCodeRelayClient(
            source: .personal,
            token: "unit-test-relay-token-0000000000000001",
            transport: http,
            streamTransport: sse
        )

        var deliveries: [FerminRelayStreamDelivery] = []
        for try await delivery in client.stream(lastEventID: 100) {
            deliveries.append(delivery)
        }
        #expect(deliveries.count == 2)
        #expect(deliveries[0].cursorAction == .reset(3))
        #expect(deliveries[1].eventID == 4)
        #expect(deliveries[1].cursorAction == .commit(4))

        var persisted = FerminRelaySSECursor(lastEventID: 100)
        for delivery in deliveries { try persisted.apply(delivery.cursorAction) }
        #expect(persisted.lastEventID == 4)
    }

    @Test
    func deliveryBufferOverflowFailsInsteadOfSilentlyDropping() async throws {
        let http = FerminCodeRelayMockHTTPTransport(
            response: .init(statusCode: 200, body: Data("{}".utf8))
        )
        let frames = (1...20).map { id in
            "id: \(id)\nevent: future_event\ndata: {\"id\":\(id)}\n\n"
        }.joined()
        let sse = FerminCodeRelayMockSSETransport(chunks: [Data(frames.utf8)])
        let client = try FerminCodeRelayClient(
            source: .personal,
            token: "unit-test-relay-token-0000000000000001",
            transport: http,
            streamTransport: sse,
            configuration: .init(maximumBufferedSSEDeliveries: 1)
        )
        let stream = client.stream()
        try await Task.sleep(nanoseconds: 30_000_000)
        do {
            for try await _ in stream {}
            Issue.record("Delivery overflow completed silently")
        } catch let error as FerminRelayHTTPError {
            #expect(error == .streamBufferOverflow(stage: .deliveries))
            #expect(error.requiresFullRefetch)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func byteBufferOverflowFailsInsteadOfDroppingAChunk() async throws {
        var continuation: AsyncThrowingStream<Data, Error>.Continuation?
        let stream = AsyncThrowingStream<Data, Error>(
            bufferingPolicy: .bufferingOldest(1)
        ) { continuation = $0 }
        let activeContinuation = try #require(continuation)
        #expect(FerminRelayURLSessionTransport.yieldChunk(Data([1]), to: activeContinuation))
        #expect(!FerminRelayURLSessionTransport.yieldChunk(Data([2]), to: activeContinuation))

        var iterator = stream.makeAsyncIterator()
        #expect(try await iterator.next() == Data([1]))
        do {
            _ = try await iterator.next()
            Issue.record("Byte overflow completed silently")
        } catch let error as FerminRelayHTTPError {
            #expect(error == .streamBufferOverflow(stage: .bytes))
            #expect(error.requiresFullRefetch)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func sessionUpsertRequiresIdentityAndNormalizedWrapperTriggersFullRefresh() throws {
        let wrapper = FerminRelaySSEEvent(
            id: 7,
            name: "session_upserted",
            data: Data(
                "{\"method\":\"thread/name/updated\",\"threadId\":\"thread-1\",\"params\":{}}".utf8
            )
        )
        if case let .refreshTarget(name, target) = try FerminRelayStreamEventDecoder.decode(wrapper) {
            #expect(name == "session_upserted")
            #expect(target.windowID == nil)
            #expect(target.sessionID == nil)
        } else {
            Issue.record("Normalized wrapper did not request a full refresh")
        }

        let invalid = FerminRelaySSEEvent(
            id: 8,
            name: "session_upserted",
            data: Data("{\"windowId\":\"window-only\",\"displayName\":\"Invalid\"}".utf8)
        )
        do {
            _ = try FerminRelayStreamEventDecoder.decode(invalid)
            Issue.record("Session without both identities was accepted")
        } catch let error as FerminRelayStreamEventDecodingError {
            #expect(error == .invalidSessionIdentity)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func clientStreamUsesReplayHeaderAndDecodesOmittedMarker() async throws {
        let http = FerminCodeRelayMockHTTPTransport(
            response: .init(statusCode: 200, body: Data("{}".utf8))
        )
        let sse = FerminCodeRelayMockSSETransport(chunks: [
            Data("id: 8\nevent: command_state_changed\ndata: {\"commandId\":\"c\",\"state\":\"completed\"}\n\n".utf8),
            Data("id: 9\nevent: event_omitted\ndata: {\"ok\":false,\"code\":\"SSE_EVENT_PAYLOAD_OMITTED\",\"reason\":\"payloadTooLarge\",\"originalEvent\":\"snapshot\",\"originalBytes\":2000000,\"refetchRequired\":true}\n\n".utf8),
        ])
        let client = try FerminCodeRelayClient(
            source: .puky,
            token: "unit-test-relay-token-0000000000000001",
            transport: http,
            streamTransport: sse
        )

        var deliveries: [FerminRelayStreamDelivery] = []
        for try await delivery in client.stream(lastEventID: 7) {
            deliveries.append(delivery)
        }

        #expect(deliveries.map(\.eventID) == [8, 9])
        if case let .commandStateChanged(event) = deliveries[0].event {
            #expect(event.commandID == "c")
            #expect(event.state == .completed)
        } else {
            Issue.record("Expected command state event")
        }
        if case let .eventOmitted(event) = deliveries[1].event {
            #expect(event.refetchRequired)
            #expect(event.originalEvent == "snapshot")
        } else {
            Issue.record("Expected omitted event marker")
        }
        #expect(await sse.lastRequest()?.value(forHTTPHeaderField: "Last-Event-ID") == "7")
        #expect(await sse.lastRequest()?.url?.path.hasPrefix("/fermin-code-puky/") == true)
    }
}
