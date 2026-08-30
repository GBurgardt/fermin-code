import XCTest
@testable import KyCode

final class VoiceTranscriptionTests: XCTestCase {
    @MainActor
    func testPendingAcknowledgementIsPublishedWithinFiveHundredMilliseconds() {
        let store = KycodeConnectionStore()
        let startedAt = ContinuousClock.now

        let job = store.beginVoiceTranscription(windowId: "audio-qa", duration: 10)
        let elapsed = startedAt.duration(to: .now)

        XCTAssertLessThan(elapsed, .milliseconds(500))
        XCTAssertEqual(store.voiceTranscriptionJobs[job.id]?.phase, .preparing)
        XCTAssertEqual(job.messageId, store.voiceTranscriptionJobs[job.id]?.messageId)
        XCTAssertEqual(
            VoiceTranscriptionPolicy.statusTitle(for: job.phase.messageStatus),
            "Enviado · preparando audio"
        )
    }

    func testDeltasMutateOneStableMessageInsteadOfCreatingNewMessages() {
        let pending = VoiceTranscriptionJob.pending(
            windowId: "audio-qa",
            duration: 10,
            id: "stable-job"
        )

        let first = pending.applying(delta: "hola ")
        let second = first.applying(delta: "mundo")

        XCTAssertEqual(second.id, pending.id)
        XCTAssertEqual(second.messageId, pending.messageId)
        XCTAssertEqual(second.transcriptText, "hola mundo")
        XCTAssertEqual(second.phase, .transcribing)
    }

    func testCompletedTranscriptKeepsIdentityAndMovesToSending() {
        let pending = VoiceTranscriptionJob.pending(
            windowId: "audio-qa",
            duration: 10,
            id: "stable-job"
        )
        let completed = pending.replacingTranscript(with: "texto final")

        XCTAssertEqual(completed.messageId, pending.messageId)
        XCTAssertEqual(completed.transcriptText, "texto final")
        XCTAssertEqual(completed.phase, .sending)
    }

    func testVoiceOwnerRejectsSameRemoteWindowAcrossProfilesAndGenerations() {
        let personalRoute = VoiceTranscriptionRouteIdentity(
            selectedProfileId: "personal",
            routedProfileId: "personal",
            presentedWindowId: "shared-window",
            remoteWindowId: "shared-window",
            baseURL: "https://relay.example.com/fermin-code",
            sessionId: "personal-session"
        )
        let pukyRoute = VoiceTranscriptionRouteIdentity(
            selectedProfileId: "puky",
            routedProfileId: "puky",
            presentedWindowId: "shared-window",
            remoteWindowId: "shared-window",
            baseURL: "https://relay.example.com/fermin-code-puky",
            sessionId: "puky-session"
        )
        let expected = VoiceTranscriptionOwner(
            connectionGeneration: 10,
            route: personalRoute,
            requiresDurableContract: true
        )

        XCTAssertTrue(
            VoiceTranscriptionOwnershipPolicy.owns(
                expected: expected,
                current: expected
            )
        )
        XCTAssertFalse(
            VoiceTranscriptionOwnershipPolicy.owns(
                expected: expected,
                current: VoiceTranscriptionOwner(
                    connectionGeneration: 11,
                    route: personalRoute,
                    requiresDurableContract: true
                )
            )
        )
        XCTAssertFalse(
            VoiceTranscriptionOwnershipPolicy.owns(
                expected: expected,
                current: VoiceTranscriptionOwner(
                    connectionGeneration: 10,
                    route: pukyRoute,
                    requiresDurableContract: true
                )
            )
        )
        XCTAssertFalse(
            VoiceTranscriptionOwnershipPolicy.owns(
                expected: nil,
                current: expected
            )
        )
        XCTAssertTrue(
            VoiceTranscriptionOwnershipPolicy.routeMatches(
                expected: personalRoute,
                current: personalRoute
            )
        )
        XCTAssertFalse(
            VoiceTranscriptionOwnershipPolicy.routeMatches(
                expected: personalRoute,
                current: pukyRoute
            )
        )
    }

    func testTimeoutStopsAnOperationAfterConfiguredDeadline() async {
        do {
            _ = try await VoiceTranscriptionTimeout.run(for: .milliseconds(20)) {
                try await Task.sleep(for: .seconds(1))
                return "late"
            }
            XCTFail("Expected a timeout")
        } catch VoiceTranscriptionError.timedOut {
            XCTAssertTrue(true)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testWaveParserAcceptsRecorderFormat() throws {
        let pcm = Data([0, 0, 1, 0, 255, 127, 0, 128])
        let wave = makeWave(pcm: pcm, sampleRate: 16_000, channels: 1, bitsPerSample: 16)

        let parsed = try PCM16WavePayload.read(from: wave)

        XCTAssertEqual(parsed.sampleRate, 16_000)
        XCTAssertEqual(parsed.channels, 1)
        XCTAssertEqual(parsed.bytes, pcm)
    }

    func testWaveParserRejectsUnsupportedRecorderFormat() {
        let wave = makeWave(
            pcm: Data([0, 0, 1, 0]),
            sampleRate: 44_100,
            channels: 2,
            bitsPerSample: 16
        )

        XCTAssertThrowsError(try PCM16WavePayload.read(from: wave)) { error in
            guard case VoiceTranscriptionError.unsupportedWaveFormat = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testFailureStatusOffersAStableRetryTarget() {
        let pending = VoiceTranscriptionJob.pending(
            windowId: "audio-qa",
            duration: 10,
            id: "retry-job"
        )
        let failed = pending.failing(with: "Sin red")

        XCTAssertEqual(failed.messageId, pending.messageId)
        XCTAssertEqual(failed.phase, .failed)
        XCTAssertEqual(failed.errorMessage, "Sin red")
        XCTAssertEqual(
            VoiceTranscriptionPolicy.statusTitle(for: failed.phase.messageStatus),
            "Transcripción fallida"
        )
    }

    func testVoxtralBatchIsTheDefaultForRecordedWaveAudio() {
        XCTAssertFalse(
            MistralTranscriptionModePolicy.shouldUseRealtime(
                preferRealtime: false,
                fileExtension: "wav"
            )
        )
    }

    func testVoxtralRealtimeRequiresExplicitOptInAndWaveAudio() {
        XCTAssertTrue(
            MistralTranscriptionModePolicy.shouldUseRealtime(
                preferRealtime: true,
                fileExtension: "WAV"
            )
        )
        XCTAssertFalse(
            MistralTranscriptionModePolicy.shouldUseRealtime(
                preferRealtime: true,
                fileExtension: "m4a"
            )
        )
    }

    func testVoxtralRealtimePreferenceParsesOnlyAffirmativeValues() {
        XCTAssertTrue(MistralTranscriptionModePolicy.parseBoolean("true"))
        XCTAssertTrue(MistralTranscriptionModePolicy.parseBoolean(" 1 "))
        XCTAssertFalse(MistralTranscriptionModePolicy.parseBoolean(nil))
        XCTAssertFalse(MistralTranscriptionModePolicy.parseBoolean("false"))
    }

    func testVoxtralDiarizationRequestIsExplicitAndOptIn() {
        let standard = MistralTranscriptionRequestPolicy.fields(
            model: "voxtral-mini-latest",
            language: "es",
            diarize: false
        )
        let diarized = MistralTranscriptionRequestPolicy.fields(
            model: "voxtral-mini-latest",
            language: "es",
            diarize: true
        )

        XCTAssertNil(standard["diarize"])
        XCTAssertNil(standard["timestamp_granularities"])
        XCTAssertEqual(diarized["diarize"], "true")
        XCTAssertEqual(diarized["timestamp_granularities"], "segment")
        XCTAssertEqual(diarized["temperature"], "0")
    }

    func testVoxtralDecoderPreservesFullTextAndSpeakerSegments() throws {
        let fixture = Data(
            """
            {
              "model": "voxtral-mini-2607",
              "text": " Hola desde adelante. Mensaje del fondo. ",
              "segments": [
                {"text":" Hola desde adelante. ","start":0.0,"end":1.75,"speaker_id":"speaker_0"},
                {"text":"Mensaje del fondo.","start":1.75,"end":3.5,"speaker_id":"speaker_1"}
              ]
            }
            """.utf8
        )

        let result = try MistralTranscriptionResponseDecoder.decode(
            data: fixture,
            modelFallback: "fallback",
            latencyMilliseconds: 42
        )

        XCTAssertEqual(result.fullText, "Hola desde adelante. Mensaje del fondo.")
        XCTAssertEqual(result.model, "voxtral-mini-2607")
        XCTAssertEqual(result.latencyMilliseconds, 42)
        XCTAssertEqual(result.segments.map(\.speakerId), ["speaker_0", "speaker_1"])
        XCTAssertEqual(result.segments.map(\.id), ["voxtral-0-0", "voxtral-1-1750"])
    }

    func testVoxtralDecoderFiltersInvalidSegmentsWithoutLosingTranscript() throws {
        let fixture = Data(
            """
            {
              "text": "texto completo seguro",
              "segments": [
                {"text":"sin duración","start":2.0,"end":2.0,"speaker_id":null},
                {"text":"   ","start":2.0,"end":3.0,"speaker_id":"speaker_0"}
              ]
            }
            """.utf8
        )

        let result = try MistralTranscriptionResponseDecoder.decode(
            data: fixture,
            modelFallback: "voxtral-mini-latest",
            latencyMilliseconds: 10
        )

        XCTAssertEqual(result.fullText, "texto completo seguro")
        XCTAssertTrue(result.segments.isEmpty)
        XCTAssertEqual(result.model, "voxtral-mini-latest")
    }

    func testVoxtralMultipartContainsDiarizationFlag() throws {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mistral-multipart-\(UUID().uuidString).wav")
        try Data([0, 1, 2, 3]).write(to: temporaryURL)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let body = try MistralMultipartFormData.body(
            fields: MistralTranscriptionRequestPolicy.fields(
                model: "voxtral-mini-latest",
                language: "es",
                diarize: true
            ),
            fileFieldName: "file",
            fileURL: temporaryURL,
            mimeType: "audio/wav",
            boundary: "fixture-boundary"
        )
        let rendered = try XCTUnwrap(String(data: body, encoding: .utf8))

        XCTAssertTrue(rendered.contains("name=\"diarize\"\r\n\r\ntrue"))
        XCTAssertTrue(rendered.contains("filename=\"\(temporaryURL.lastPathComponent)\""))
        XCTAssertTrue(rendered.hasSuffix("--fixture-boundary--\r\n"))
    }

    private func makeWave(
        pcm: Data,
        sampleRate: UInt32,
        channels: UInt16,
        bitsPerSample: UInt16
    ) -> Data {
        var data = Data()
        data.append(Data("RIFF".utf8))
        appendUInt32(36 + UInt32(pcm.count), to: &data)
        data.append(Data("WAVE".utf8))
        data.append(Data("fmt ".utf8))
        appendUInt32(16, to: &data)
        appendUInt16(1, to: &data)
        appendUInt16(channels, to: &data)
        appendUInt32(sampleRate, to: &data)
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        appendUInt32(byteRate, to: &data)
        appendUInt16(channels * (bitsPerSample / 8), to: &data)
        appendUInt16(bitsPerSample, to: &data)
        data.append(Data("data".utf8))
        appendUInt32(UInt32(pcm.count), to: &data)
        data.append(pcm)
        return data
    }

    private func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 24) & 0xff))
    }
}

final class VoxtralDiarizationLiveTests: XCTestCase {
    func testLiveTwoSpeakerFixtureReturnsTimedSpeakerTurns() async throws {
        guard ProcessInfo.processInfo.environment["KYCODE_RUN_LIVE_ISOLATION_QA"] == "1" else {
            throw XCTSkip("Set KYCODE_RUN_LIVE_ISOLATION_QA=1 to use the configured Mistral account.")
        }
        guard let path = ProcessInfo.processInfo.environment["KYCODE_ISOLATION_AUDIO_FIXTURE"],
              FileManager.default.fileExists(atPath: path) else {
            XCTFail("KYCODE_ISOLATION_AUDIO_FIXTURE must point to a two-speaker WAV fixture.")
            return
        }

        let service = try MistralTranscriptionService.configured()
        let result = try await service.transcribeAudioFileDetailed(
            filePath: path,
            diarize: true
        )
        let speakerIDs = Set(result.segments.compactMap(\.speakerId))

        XCTAssertFalse(result.fullText.isEmpty)
        XCTAssertGreaterThanOrEqual(result.segments.count, 2)
        XCTAssertGreaterThanOrEqual(speakerIDs.count, 2)
        XCTAssertTrue(result.segments.allSatisfy { $0.end > $0.start })

        let evidence = XCTAttachment(string: """
        model=\(result.model)
        latency_ms=\(result.latencyMilliseconds)
        segment_count=\(result.segments.count)
        speaker_count=\(speakerIDs.count)
        duration_seconds=\(result.segments.map(\.end).max() ?? 0)
        """)
        evidence.name = "voxtral-live-diarization-evidence"
        evidence.lifetime = .keepAlways
        add(evidence)
    }
}
