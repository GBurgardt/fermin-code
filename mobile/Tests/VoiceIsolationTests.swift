import Foundation
import XCTest
@testable import KyCode

final class VoiceIsolationTests: XCTestCase {
    private struct FixtureVerifier: VoiceSpeakerVerifying {
        let result: [String: VoiceSegmentVerification]

        func verify(
            waveFileURL: URL,
            segments: [VoiceTranscriptionSegment]
        ) async throws -> [String: VoiceSegmentVerification] {
            result
        }
    }

    private struct FailingVerifier: VoiceSpeakerVerifying {
        let error: VoiceSpeakerVerificationError

        func verify(
            waveFileURL: URL,
            segments: [VoiceTranscriptionSegment]
        ) async throws -> [String: VoiceSegmentVerification] {
            throw error
        }
    }

    func testPreferencesDefaultToPersonalizedAndClampThreshold() throws {
        let suiteName = "VoiceIsolationTests-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(VoiceIsolationPreferences.loadMode(from: suite), .personalized)
        XCTAssertEqual(VoiceIsolationPreferences.loadThreshold(from: suite), 0.55, accuracy: 0.001)

        VoiceIsolationPreferences.saveMode(.off, to: suite)
        VoiceIsolationPreferences.saveThreshold(4, to: suite)
        XCTAssertEqual(VoiceIsolationPreferences.loadMode(from: suite), .off)
        XCTAssertEqual(VoiceIsolationPreferences.loadThreshold(from: suite), 0.95, accuracy: 0.001)
    }

    func testDisabledIsolationAlwaysPreservesFullText() {
        let result = makeResult()
        let report = VoiceIsolationPolicy.decide(
            transcription: result,
            mode: .off,
            threshold: 0.55,
            verifications: [:]
        )

        XCTAssertFalse(report.applied)
        XCTAssertEqual(report.selectedText, result.fullText)
        XCTAssertEqual(report.fallbackReason, .disabled)
    }

    func testMissingSegmentsFallsBackWithoutLosingText() {
        let result = VoiceTranscriptionResult(
            fullText: "texto completo seguro",
            model: "fixture",
            latencyMilliseconds: 10
        )
        let report = VoiceIsolationPolicy.decide(
            transcription: result,
            mode: .personalized,
            threshold: 0.55,
            verifications: [:]
        )

        XCTAssertFalse(report.applied)
        XCTAssertEqual(report.selectedText, "texto completo seguro")
        XCTAssertEqual(report.fallbackReason, .missingDiarizationSegments)
    }

    func testConfidentTargetSegmentsAreSelectedInOriginalOrder() {
        let result = makeResult()
        let report = VoiceIsolationPolicy.decide(
            transcription: result,
            mode: .personalized,
            threshold: 0.55,
            verifications: [
                "one": VoiceSegmentVerification(segmentId: "one", scores: [0.83, 0.91], validFrameCount: 2),
                "two": VoiceSegmentVerification(segmentId: "two", scores: [0.12, 0.21], validFrameCount: 2),
                "three": VoiceSegmentVerification(segmentId: "three", scores: [0.74, 0.80], validFrameCount: 2)
            ]
        )

        XCTAssertTrue(report.applied)
        XCTAssertEqual(report.selectedText, "hola equipo seguimos probando ahora")
        XCTAssertEqual(report.acceptedSegments.map(\.id), ["one", "three"])
        XCTAssertEqual(report.rejectedSegments.map(\.id), ["two"])
        XCTAssertEqual(try XCTUnwrap(report.aggregateConfidence), 0.82, accuracy: 0.001)
    }

    func testInsufficientEvidenceFallsBackToFullTranscript() {
        let result = makeResult()
        let report = VoiceIsolationPolicy.decide(
            transcription: result,
            mode: .personalized,
            threshold: 0.55,
            verifications: [
                "one": VoiceSegmentVerification(segmentId: "one", scores: [0.9], validFrameCount: 1)
            ]
        )

        XCTAssertFalse(report.applied)
        XCTAssertEqual(report.selectedText, result.fullText)
        XCTAssertEqual(report.fallbackReason, .insufficientVoiceEvidence)
    }

    func testSingleHighScoreFrameCannotSelectATurn() {
        let result = makeResult()
        let report = VoiceIsolationPolicy.decide(
            transcription: result,
            mode: .personalized,
            threshold: 0.55,
            verifications: [
                "one": VoiceSegmentVerification(segmentId: "one", scores: [0.99], validFrameCount: 1),
                "two": VoiceSegmentVerification(segmentId: "two", scores: [0.10], validFrameCount: 1)
            ]
        )

        XCTAssertFalse(report.applied)
        XCTAssertEqual(report.selectedText, result.fullText)
        XCTAssertEqual(report.fallbackReason, .noTargetSegments)
        XCTAssertTrue(report.acceptedSegments.isEmpty)
    }

    func testAcceptedDurationGuardRejectsTinyTargetSlice() {
        let segments = [
            VoiceTranscriptionSegment(id: "target", speakerId: "0", start: 0, end: 0.5, text: "yo digo algo"),
            VoiceTranscriptionSegment(id: "background", speakerId: "1", start: 0.5, end: 10, text: "el fondo sigue hablando durante mucho tiempo")
        ]
        let result = VoiceTranscriptionResult(
            fullText: segments.map(\.text).joined(separator: " "),
            segments: segments,
            model: "fixture",
            latencyMilliseconds: 10
        )
        let report = VoiceIsolationPolicy.decide(
            transcription: result,
            mode: .personalized,
            threshold: 0.55,
            verifications: [
                "target": VoiceSegmentVerification(segmentId: "target", scores: [0.9, 0.91], validFrameCount: 2),
                "background": VoiceSegmentVerification(segmentId: "background", scores: [0.1, 0.2], validFrameCount: 2)
            ]
        )

        XCTAssertFalse(report.applied)
        XCTAssertEqual(report.fallbackReason, .acceptedDurationTooLow)
        XCTAssertEqual(report.selectedText, result.fullText)
        XCTAssertEqual(report.isolatedText, "yo digo algo")
    }

    func testPCMUtilitiesDecodeLittleEndianAndSliceWithClampedPadding() throws {
        let samples = [Int16.min, -2, -1, 0, 1, 2, Int16.max, 12]
        var bytes = Data()
        for sample in samples {
            var value = sample.littleEndian
            bytes.append(withUnsafeBytes(of: &value) { Data($0) })
        }
        let payload = PCM16WavePayload(sampleRate: 4, channels: 1, bytes: bytes)

        let decoded = VoicePCMUtilities.int16Samples(from: payload)
        let sliced = VoicePCMUtilities.slice(
            samples: decoded,
            sampleRate: 4,
            start: 0.5,
            end: 1.25,
            padding: 0.25
        )

        XCTAssertEqual(decoded, samples)
        XCTAssertEqual(sliced, Array(samples[1..<6]))
    }

    func testReportRoundTripsForDurableDraftMetadata() throws {
        let result = makeResult()
        let report = VoiceIsolationPolicy.decide(
            transcription: result,
            mode: .personalized,
            threshold: 0.55,
            verifications: [
                "one": VoiceSegmentVerification(segmentId: "one", scores: [0.9, 0.8], validFrameCount: 2),
                "two": VoiceSegmentVerification(segmentId: "two", scores: [0.1, 0.2], validFrameCount: 2),
                "three": VoiceSegmentVerification(segmentId: "three", scores: [0.9, 0.8], validFrameCount: 2)
            ]
        )

        let data = try JSONEncoder().encode(report)
        XCTAssertEqual(try JSONDecoder().decode(VoiceIsolationReport.self, from: data), report)
    }

    func testVoiceDraftFromOlderBuildDecodesWithoutIsolationReport() throws {
        struct LegacyVoiceDraft: Codable {
            let id: String
            let windowId: String
            let filePath: String
            let duration: TimeInterval
            let createdAt: Date
            let transcriptStatus: TranscriptStatus
            let transcriptText: String?
            let sendStatus: SendStatus
            let errorMessage: String?
        }

        let legacy = LegacyVoiceDraft(
            id: "legacy-draft",
            windowId: "window-1",
            filePath: "/tmp/legacy.wav",
            duration: 8.5,
            createdAt: Date(timeIntervalSince1970: 42),
            transcriptStatus: .pending,
            transcriptText: nil,
            sendStatus: .idle,
            errorMessage: nil
        )

        let decoded = try JSONDecoder().decode(
            VoiceDraft.self,
            from: JSONEncoder().encode(legacy)
        )
        XCTAssertEqual(decoded.id, legacy.id)
        XCTAssertNil(decoded.isolationReport)
        XCTAssertNil(decoded.routeIdentity)
    }

    func testMissingVoiceDraftFileRemainsVisibleAsRecoverableEvidence() {
        let draft = VoiceDraft(
            id: "missing-audio",
            windowId: "window-1",
            filePath: "/tmp/kycode-definitely-missing-audio.wav",
            duration: 120,
            createdAt: Date(),
            transcriptStatus: .failed,
            transcriptText: nil,
            sendStatus: .failed,
            errorMessage: "No encontré el audio.",
            isolationReport: nil
        )

        XCTAssertFalse(draft.hasAudioFile)
        XCTAssertTrue(draft.isRecoverable)
    }

    func testConfirmedSentVoiceDraftIsNoLongerRecoverable() {
        let draft = VoiceDraft(
            id: "sent-audio",
            windowId: "window-1",
            filePath: "/tmp/kycode-sent-audio.wav",
            duration: 12,
            createdAt: Date(),
            transcriptStatus: .success,
            transcriptText: "mensaje enviado",
            sendStatus: .sent,
            errorMessage: nil,
            isolationReport: nil
        )

        XCTAssertFalse(draft.isRecoverable)
    }

    func testProcessorUsesVerifierResultEndToEnd() async {
        let report = await VoiceIsolationProcessor.apply(
            transcription: makeResult(),
            waveFileURL: URL(fileURLWithPath: "/tmp/fixture.wav"),
            mode: .personalized,
            threshold: 0.55,
            verifier: FixtureVerifier(result: [
                "one": VoiceSegmentVerification(segmentId: "one", scores: [0.9, 0.8], validFrameCount: 2),
                "two": VoiceSegmentVerification(segmentId: "two", scores: [0.1, 0.2], validFrameCount: 2),
                "three": VoiceSegmentVerification(segmentId: "three", scores: [0.9, 0.8], validFrameCount: 2)
            ])
        )

        XCTAssertTrue(report.applied)
        XCTAssertEqual(report.selectedText, "hola equipo seguimos probando ahora")
    }

    func testProcessorMapsMissingProfileToSafeFullTranscriptFallback() async {
        let result = makeResult()
        let report = await VoiceIsolationProcessor.apply(
            transcription: result,
            waveFileURL: URL(fileURLWithPath: "/tmp/fixture.wav"),
            mode: .personalized,
            threshold: 0.55,
            verifier: FailingVerifier(error: .profileUnavailable)
        )

        XCTAssertFalse(report.applied)
        XCTAssertEqual(report.selectedText, result.fullText)
        XCTAssertEqual(report.fallbackReason, .profileUnavailable)
    }

    func testAppleOnlyModeSkipsSpeakerVerificationAndKeepsFullText() async {
        let result = makeResult()
        let report = await VoiceIsolationProcessor.apply(
            transcription: result,
            waveFileURL: URL(fileURLWithPath: "/tmp/fixture.wav"),
            mode: .appleProcessing,
            threshold: 0.55,
            verifier: FailingVerifier(error: .profileUnavailable)
        )

        XCTAssertEqual(report.selectedText, result.fullText)
        XCTAssertEqual(report.fallbackReason, .speakerVerificationNotRequested)
    }

    func testEvaluationMeasuresWERAndBackgroundLeakage() {
        let clean = VoiceIsolationMetrics.evaluate(
            targetReference: "Árbol rojo, casa azul",
            backgroundReference: "stream verde remoto",
            output: "arbol rojo casa azul"
        )
        XCTAssertEqual(clean.targetWordErrorRate, 0, accuracy: 0.0001)
        XCTAssertEqual(clean.backgroundWordRetentionRate, 0, accuracy: 0.0001)

        let mixed = VoiceIsolationMetrics.evaluate(
            targetReference: "árbol rojo casa azul",
            backgroundReference: "stream verde remoto",
            output: "árbol rojo stream verde remoto"
        )
        XCTAssertEqual(mixed.targetWordErrorRate, 0.75, accuracy: 0.0001)
        XCTAssertEqual(mixed.backgroundWordRetentionRate, 1, accuracy: 0.0001)
        XCTAssertEqual(mixed.backgroundDiscriminativeWordCount, 3)
        XCTAssertEqual(mixed.outputWordCount, 5)
    }

    func testBackgroundLeakageIgnoresWordsAlsoRequiredByTarget() {
        let clean = VoiceIsolationMetrics.evaluate(
            targetReference: "hola el mundo",
            backgroundReference: "el partido nuevo",
            output: "hola el mundo"
        )
        XCTAssertEqual(clean.backgroundDiscriminativeWordCount, 2)
        XCTAssertEqual(clean.backgroundWordRetentionRate, 0, accuracy: 0.0001)

        let leaked = VoiceIsolationMetrics.evaluate(
            targetReference: "hola el mundo",
            backgroundReference: "el partido nuevo",
            output: "hola el mundo partido"
        )
        XCTAssertEqual(leaked.backgroundWordRetentionRate, 0.5, accuracy: 0.0001)
    }

    func testRelativeWERImprovementHandlesBaselineAndZeroSafely() {
        XCTAssertEqual(
            VoiceIsolationMetrics.relativeWERImprovement(baseline: 0.40, candidate: 0.30),
            0.25,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            VoiceIsolationMetrics.relativeWERImprovement(baseline: 0, candidate: 0),
            0,
            accuracy: 0.0001
        )
    }

    func testKnownSpeakerReferenceIsProtectedBoundedAndDeletable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-reference-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VoiceKnownSpeakerReferenceStore(directory: directory)
        let twelveSeconds = Data(
            repeating: 0x2A,
            count: 12 * 16_000 * MemoryLayout<Int16>.size
        )

        let url = try store.save(
            from: PCM16WavePayload(sampleRate: 16_000, channels: 1, bytes: twelveSeconds)
        )
        let stored = try PCM16WavePayload.read(from: Data(contentsOf: url))

        XCTAssertEqual(stored.bytes.count, 10 * 16_000 * MemoryLayout<Int16>.size)
        XCTAssertEqual(store.availableReferenceURL(), url)
        store.deleteReference()
        XCTAssertNil(store.availableReferenceURL())
    }

    private func makeResult() -> VoiceTranscriptionResult {
        let segments = [
            VoiceTranscriptionSegment(id: "one", speakerId: "speaker_0", start: 0, end: 2, text: "hola equipo"),
            VoiceTranscriptionSegment(id: "two", speakerId: "speaker_1", start: 2, end: 4, text: "mensaje del streamer"),
            VoiceTranscriptionSegment(id: "three", speakerId: "speaker_0", start: 4, end: 6, text: "seguimos probando ahora")
        ]
        return VoiceTranscriptionResult(
            fullText: segments.map(\.text).joined(separator: " "),
            segments: segments,
            model: "fixture",
            latencyMilliseconds: 10
        )
    }

}

final class VoiceIsolationCorpusLiveTests: XCTestCase {
    private struct Manifest: Decodable, Sendable {
        struct Reference: Decodable, Sendable {
            let file: String
            let transcript: String
            let durationSeconds: Double
        }

        struct Case: Decodable, Sendable {
            let id: String
            let file: String
            let requestedSNRDB: Double
            let effectiveOverlapSNRDB: Double?
            let overlapPercent: Int
        }

        let target: Reference
        let background: Reference
        let cases: [Case]
    }

    private struct CaseEvidence: Codable, Sendable {
        let id: String
        let requestedSNRDB: Double
        let effectiveOverlapSNRDB: Double?
        let overlapPercent: Int
        let baseline: VoiceIsolationEvaluation
        let candidate: VoiceIsolationEvaluation
        let isolationApplied: Bool
        let fallbackReason: String?
        let aggregateConfidence: Float?
        let voxtralLatencyMilliseconds: Int
        let verificationLatencyMilliseconds: Int
    }

    private struct CorpusEvidence: Codable, Sendable {
        let caseCount: Int
        let cleanFrameAcceptanceRate: Double
        let backgroundFrameFalseAcceptanceRate: Double
        let baselineMeanWER: Double
        let candidateMeanWER: Double
        let relativeWERImprovement: Double
        let candidateMeanBackgroundRetentionRate: Double
        let cases: [CaseEvidence]
    }

    private struct BaselineCaseEvidence: Codable, Sendable {
        let id: String
        let requestedSNRDB: Double
        let effectiveOverlapSNRDB: Double?
        let overlapPercent: Int
        let evaluation: VoiceIsolationEvaluation
        let voxtralLatencyMilliseconds: Int
    }

    private struct BaselineCorpusEvidence: Codable, Sendable {
        let caseCount: Int
        let meanWER: Double
        let meanBackgroundRetentionRate: Double
        let meanVoxtralLatencyMilliseconds: Double
        let cases: [BaselineCaseEvidence]
    }

    private final class MemoryProfileStore: VoiceSpeakerProfileStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var profile: Data?

        func loadProfile() -> Data? {
            lock.withLock { profile }
        }

        func saveProfile(_ profile: Data) -> Bool {
            guard !profile.isEmpty else { return false }
            lock.withLock { self.profile = profile }
            return true
        }

        func deleteProfile() {
            lock.withLock { profile = nil }
        }
    }

    func testLiveVoxtralBaselineCorpusProducesEvidence() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["KYCODE_RUN_LIVE_CORPUS_BASELINE_QA"] == "1" else {
            throw XCTSkip("Set KYCODE_RUN_LIVE_CORPUS_BASELINE_QA=1 to run baseline corpus QA.")
        }
        guard let manifestPath = environment["KYCODE_VOICE_CORPUS_MANIFEST"],
              FileManager.default.fileExists(atPath: manifestPath) else {
            XCTFail("KYCODE_VOICE_CORPUS_MANIFEST must point to a generated manifest.json.")
            return
        }

        let manifestURL = URL(fileURLWithPath: manifestPath)
        let root = manifestURL.deletingLastPathComponent()
        let manifest = try JSONDecoder().decode(
            Manifest.self,
            from: Data(contentsOf: manifestURL)
        )
        XCTAssertFalse(manifest.cases.isEmpty)

        let voxtral = try MistralTranscriptionService.configured()
        let targetTranscript = manifest.target.transcript
        let backgroundTranscript = manifest.background.transcript
        var cases = try await concurrentMap(manifest.cases, maxConcurrent: 4) { corpusCase in
            let transcript = try await voxtral.transcribeAudioFileDetailed(
                filePath: root.appendingPathComponent(corpusCase.file).path,
                diarize: false
            )
            return BaselineCaseEvidence(
                id: corpusCase.id,
                requestedSNRDB: corpusCase.requestedSNRDB,
                effectiveOverlapSNRDB: corpusCase.effectiveOverlapSNRDB,
                overlapPercent: corpusCase.overlapPercent,
                evaluation: VoiceIsolationMetrics.evaluate(
                    targetReference: targetTranscript,
                    backgroundReference: backgroundTranscript,
                    output: transcript.fullText
                ),
                voxtralLatencyMilliseconds: transcript.latencyMilliseconds
            )
        }
        cases.sort { $0.id < $1.id }
        let evidence = BaselineCorpusEvidence(
            caseCount: cases.count,
            meanWER: mean(cases.map { $0.evaluation.targetWordErrorRate }),
            meanBackgroundRetentionRate: mean(
                cases.map { $0.evaluation.backgroundWordRetentionRate }
            ),
            meanVoxtralLatencyMilliseconds: mean(
                cases.map { Double($0.voxtralLatencyMilliseconds) }
            ),
            cases: cases
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let attachment = XCTAttachment(
            data: try encoder.encode(evidence),
            uniformTypeIdentifier: "public.json"
        )
        attachment.name = "voice-isolation-corpus-baseline-evidence"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testLiveCorpusMeetsSpeakerIsolationGoal() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["KYCODE_RUN_LIVE_SPEAKER_QA"] == "1" else {
            throw XCTSkip("Set KYCODE_RUN_LIVE_SPEAKER_QA=1 to run Eagle + Voxtral corpus QA.")
        }
        guard let manifestPath = environment["KYCODE_VOICE_CORPUS_MANIFEST"],
              FileManager.default.fileExists(atPath: manifestPath) else {
            XCTFail("KYCODE_VOICE_CORPUS_MANIFEST must point to a generated manifest.json.")
            return
        }
        guard let accessKey = VoiceIsolationSecrets.loadPicovoiceAccessKey() else {
            throw XCTSkip("PICOVOICE_ACCESS_KEY is required for live corpus QA.")
        }

        let manifestURL = URL(fileURLWithPath: manifestPath)
        let root = manifestURL.deletingLastPathComponent()
        let manifest = try JSONDecoder().decode(
            Manifest.self,
            from: Data(contentsOf: manifestURL)
        )
        XCTAssertFalse(manifest.cases.isEmpty)

        let profileStore = MemoryProfileStore()
        let referenceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-corpus-reference-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: referenceDirectory) }
        let verifier = EagleSpeakerVerificationService(
            accessKey: accessKey,
            referenceStore: VoiceKnownSpeakerReferenceStore(directory: referenceDirectory),
            profileStore: profileStore
        )
        let targetURL = root.appendingPathComponent(manifest.target.file)
        let backgroundURL = root.appendingPathComponent(manifest.background.file)
        _ = try await verifier.enroll(waveFileURL: targetURL)

        let threshold = VoiceIsolationPreferences.defaultThreshold
        let cleanVerification = try await verifier.verify(
            waveFileURL: targetURL,
            segments: [VoiceTranscriptionSegment(
                id: "clean-target",
                speakerId: "target",
                start: 0,
                end: manifest.target.durationSeconds,
                text: manifest.target.transcript
            )]
        )["clean-target"]
        let backgroundVerification = try await verifier.verify(
            waveFileURL: backgroundURL,
            segments: [VoiceTranscriptionSegment(
                id: "clean-background",
                speakerId: "background",
                start: 0,
                end: manifest.background.durationSeconds,
                text: manifest.background.transcript
            )]
        )["clean-background"]
        let cleanAcceptance = acceptanceRate(cleanVerification?.scores ?? [], threshold: threshold)
        let backgroundFalseAcceptance = acceptanceRate(
            backgroundVerification?.scores ?? [],
            threshold: threshold
        )

        let voxtral = try MistralTranscriptionService.configured()
        let targetTranscript = manifest.target.transcript
        let backgroundTranscript = manifest.background.transcript
        var cases = try await concurrentMap(manifest.cases, maxConcurrent: 4) { corpusCase in
            let fileURL = root.appendingPathComponent(corpusCase.file)
            let baselineTranscript = try await voxtral.transcribeAudioFileDetailed(
                filePath: fileURL.path,
                diarize: false
            )
            let detailedTranscript = try await voxtral.transcribeAudioFileDetailed(
                filePath: fileURL.path,
                diarize: true
            )
            let report = await VoiceIsolationProcessor.apply(
                transcription: detailedTranscript,
                waveFileURL: fileURL,
                mode: .personalized,
                threshold: threshold,
                verifier: verifier
            )
            return CaseEvidence(
                id: corpusCase.id,
                requestedSNRDB: corpusCase.requestedSNRDB,
                effectiveOverlapSNRDB: corpusCase.effectiveOverlapSNRDB,
                overlapPercent: corpusCase.overlapPercent,
                baseline: VoiceIsolationMetrics.evaluate(
                    targetReference: targetTranscript,
                    backgroundReference: backgroundTranscript,
                    output: baselineTranscript.fullText
                ),
                candidate: VoiceIsolationMetrics.evaluate(
                    targetReference: targetTranscript,
                    backgroundReference: backgroundTranscript,
                    output: report.selectedText
                ),
                isolationApplied: report.applied,
                fallbackReason: report.fallbackReason?.rawValue,
                aggregateConfidence: report.aggregateConfidence,
                voxtralLatencyMilliseconds: detailedTranscript.latencyMilliseconds,
                verificationLatencyMilliseconds: report.verificationLatencyMilliseconds
            )
        }
        cases.sort { $0.id < $1.id }

        let baselineMeanWER = mean(cases.map { $0.baseline.targetWordErrorRate })
        let candidateMeanWER = mean(cases.map { $0.candidate.targetWordErrorRate })
        let evidence = CorpusEvidence(
            caseCount: cases.count,
            cleanFrameAcceptanceRate: cleanAcceptance,
            backgroundFrameFalseAcceptanceRate: backgroundFalseAcceptance,
            baselineMeanWER: baselineMeanWER,
            candidateMeanWER: candidateMeanWER,
            relativeWERImprovement: VoiceIsolationMetrics.relativeWERImprovement(
                baseline: baselineMeanWER,
                candidate: candidateMeanWER
            ),
            candidateMeanBackgroundRetentionRate: mean(
                cases.map { $0.candidate.backgroundWordRetentionRate }
            ),
            cases: cases
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let attachment = XCTAttachment(
            data: try encoder.encode(evidence),
            uniformTypeIdentifier: "public.json"
        )
        attachment.name = "voice-isolation-corpus-evidence"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertGreaterThanOrEqual(
            evidence.cleanFrameAcceptanceRate,
            0.90,
            "Clean target verification did not reach the 90% Goal threshold."
        )
        XCTAssertTrue(
            evidence.relativeWERImprovement >= 0.10
                || evidence.candidateMeanBackgroundRetentionRate <= 0.05,
            "Candidate missed both the relative WER and background-retention thresholds."
        )
        await verifier.deleteProfile()
    }

    private func acceptanceRate(_ scores: [Float], threshold: Float) -> Double {
        let finite = scores.filter(\.isFinite)
        guard !finite.isEmpty else { return 0 }
        return Double(finite.filter { $0 >= threshold }.count) / Double(finite.count)
    }

    private func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private func concurrentMap<Input: Sendable, Output: Sendable>(
        _ inputs: [Input],
        maxConcurrent: Int,
        operation: @escaping @Sendable (Input) async throws -> Output
    ) async throws -> [Output] {
        guard !inputs.isEmpty else { return [] }
        let limit = max(1, min(maxConcurrent, inputs.count))
        return try await withThrowingTaskGroup(of: Output.self) { group in
            var nextIndex = 0
            for _ in 0..<limit {
                let input = inputs[nextIndex]
                nextIndex += 1
                group.addTask { try await operation(input) }
            }

            var results: [Output] = []
            results.reserveCapacity(inputs.count)
            while let result = try await group.next() {
                results.append(result)
                if nextIndex < inputs.count {
                    let input = inputs[nextIndex]
                    nextIndex += 1
                    group.addTask { try await operation(input) }
                }
            }
            return results
        }
    }
}
