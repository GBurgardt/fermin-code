import Foundation
import XCTest
@testable import KyCode

final class BackgroundRecordingTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        clearPersistedRecording()
    }

    override func tearDownWithError() throws {
        clearPersistedRecording()
        try super.tearDownWithError()
    }

    func testRepairWAVRewritesStaleCrashHeaderWithoutDroppingSamples() throws {
        let url = try VoiceRecordingPersistence.makeSegmentURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let samples = Data(repeating: 0x5A, count: Int(VoiceRecordingPersistence.bytesPerSecond))
        try staleWave(samples: samples).write(to: url)

        let repaired = try VoiceRecordingPersistence.repairWAV(at: url)
        let payload = try PCM16WavePayload.read(from: Data(contentsOf: url))

        XCTAssertEqual(repaired.dataByteCount, UInt64(samples.count))
        XCTAssertEqual(repaired.duration, 1, accuracy: 0.001)
        XCTAssertEqual(payload.bytes, samples)
    }

    func testFinalRecordingStreamsMultipleRecoveredSegmentsInOrder() throws {
        let firstURL = try VoiceRecordingPersistence.makeSegmentURL()
        let secondURL = try VoiceRecordingPersistence.makeSegmentURL()
        let first = Data(repeating: 0x11, count: Int(VoiceRecordingPersistence.bytesPerSecond / 2))
        let second = Data(repeating: 0x22, count: Int(VoiceRecordingPersistence.bytesPerSecond))
        try validWave(samples: first).write(to: firstURL)
        try validWave(samples: second).write(to: secondURL)
        let manifest = makeManifest(segmentNames: [firstURL.lastPathComponent, secondURL.lastPathComponent])
        defer { VoiceRecordingPersistence.discard(manifest) }

        let result = try VoiceRecordingPersistence.makeFinalRecording(from: manifest)
        defer { try? FileManager.default.removeItem(at: result.fileURL) }
        let payload = try PCM16WavePayload.read(from: Data(contentsOf: result.fileURL))

        XCTAssertEqual(result.windowId, manifest.windowId)
        XCTAssertEqual(result.duration, 1.5, accuracy: 0.001)
        XCTAssertEqual(payload.bytes, first + second)
    }

    func testRecoveryRepairsHeaderPreservesMissingReferenceAndPersistsInterruptedManifest() throws {
        let url = try VoiceRecordingPersistence.makeSegmentURL()
        let samples = Data(repeating: 0x33, count: Int(VoiceRecordingPersistence.bytesPerSecond / 4))
        try staleWave(samples: samples).write(to: url)
        let manifest = makeManifest(segmentNames: ["missing.wav", url.lastPathComponent])
        try VoiceRecordingPersistence.save(manifest)
        defer { VoiceRecordingPersistence.discard(manifest) }

        let recovered = try XCTUnwrap(VoiceRecordingPersistence.recoverManifest())
        let persisted = try XCTUnwrap(VoiceRecordingPersistence.load())

        XCTAssertEqual(recovered.0.segmentFileNames, ["missing.wav", url.lastPathComponent])
        XCTAssertEqual(recovered.1, 0.25, accuracy: 0.001)
        XCTAssertTrue(recovered.hasPlayableAudio)
        XCTAssertEqual(persisted.phase, .interrupted)
        XCTAssertEqual(persisted.segmentFileNames, ["missing.wav", url.lastPathComponent])
        XCTAssertEqual(persisted.lastKnownDuration, 0.25, accuracy: 0.001)
    }

    func testRecoveryNeverDeletesZeroLengthEvidenceOrManifest() throws {
        let url = try VoiceRecordingPersistence.makeSegmentURL()
        try validWave(samples: Data()).write(to: url)
        let manifest = makeManifest(
            segmentNames: [url.lastPathComponent],
            lastKnownDuration: 91
        )
        try VoiceRecordingPersistence.save(manifest)

        let recovered = try XCTUnwrap(VoiceRecordingPersistence.recoverManifest())

        XCTAssertEqual(recovered.duration, 91, accuracy: 0.001)
        XCTAssertFalse(recovered.hasPlayableAudio)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNotNil(try VoiceRecordingPersistence.load())
    }

    func testRecoveryNeverDeletesManifestWhenReferencedFileIsMissing() throws {
        let manifest = makeManifest(
            segmentNames: ["segment-missing-after-crash.wav"],
            lastKnownDuration: 37
        )
        try VoiceRecordingPersistence.save(manifest)

        let recovered = try XCTUnwrap(VoiceRecordingPersistence.recoverManifest())

        XCTAssertEqual(recovered.duration, 37, accuracy: 0.001)
        XCTAssertFalse(recovered.hasPlayableAudio)
        XCTAssertEqual(try VoiceRecordingPersistence.load()?.segmentFileNames, manifest.segmentFileNames)
    }

    func testFinalizationSkipsDamagedSegmentButKeepsItOnDisk() throws {
        let damagedURL = try VoiceRecordingPersistence.makeSegmentURL()
        let validURL = try VoiceRecordingPersistence.makeSegmentURL()
        try Data("not-a-wave".utf8).write(to: damagedURL)
        let samples = Data(repeating: 0x44, count: Int(VoiceRecordingPersistence.bytesPerSecond))
        try validWave(samples: samples).write(to: validURL)
        let manifest = makeManifest(segmentNames: [damagedURL.lastPathComponent, validURL.lastPathComponent])
        defer { VoiceRecordingPersistence.discard(manifest) }

        let result = try VoiceRecordingPersistence.makeFinalRecording(from: manifest)

        XCTAssertEqual(result.fileURL, validURL)
        XCTAssertEqual(result.duration, 1, accuracy: 0.001)
        XCTAssertTrue(FileManager.default.fileExists(atPath: damagedURL.path))
    }

    func testExplicitDiscardDeletesManifestAndReferencedAudio() throws {
        let url = try VoiceRecordingPersistence.makeSegmentURL()
        try validWave(samples: Data(repeating: 0x55, count: 2_048)).write(to: url)
        let manifest = makeManifest(segmentNames: [url.lastPathComponent])
        try VoiceRecordingPersistence.save(manifest)

        VoiceRecordingPersistence.discard(manifest)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(try VoiceRecordingPersistence.load())
    }

    func testCrashRecoverableWriterCheckpointsCanonicalWAV() throws {
        let url = try VoiceRecordingPersistence.makeSegmentURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try VoiceRecordingPersistence.createCrashRecoverableWAV(at: url)
        let samples = Data(repeating: 0x66, count: Int(VoiceRecordingPersistence.bytesPerSecond / 2))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: samples)
        try VoiceRecordingPersistence.checkpointWAV(handle, dataByteCount: UInt64(samples.count))
        try handle.close()

        let info = try VoiceRecordingPersistence.repairWAV(at: url)

        XCTAssertEqual(info.dataByteCount, UInt64(samples.count))
        XCTAssertEqual(info.duration, 0.5, accuracy: 0.001)
    }

    func testManifestRoundTripPreservesStableRecordingIdentity() throws {
        let manifest = makeManifest(segmentNames: ["segment-a.wav", "segment-b.wav"])
        try VoiceRecordingPersistence.save(manifest)
        defer { VoiceRecordingPersistence.discard(manifest) }

        XCTAssertEqual(try VoiceRecordingPersistence.load(), manifest)
    }

    func testInterruptedCaptureIsNeverPresentedAsLiveRecording() {
        XCTAssertTrue(
            VoiceCaptureContinuityPolicy.displaysLiveCapture(
                phase: .recording,
                belongsToSession: true
            )
        )
        XCTAssertFalse(
            VoiceCaptureContinuityPolicy.displaysLiveCapture(
                phase: .interrupted,
                belongsToSession: true
            ),
            "The UI must not claim the microphone is live after the recorder stopped."
        )
        XCTAssertFalse(
            VoiceCaptureContinuityPolicy.displaysLiveCapture(
                phase: .recording,
                belongsToSession: false
            )
        )
    }

    func testCaptureContinuityRepairsStoppedAndInterruptedRecorderOnlyForActiveIntent() {
        XCTAssertTrue(
            VoiceCaptureContinuityPolicy.shouldResumeCapture(
                continuationRequested: true,
                phase: .recording,
                isBackgrounded: false,
                recorderIsLive: false
            )
        )
        XCTAssertTrue(
            VoiceCaptureContinuityPolicy.shouldResumeCapture(
                continuationRequested: true,
                phase: .interrupted,
                isBackgrounded: false,
                recorderIsLive: false
            )
        )
        XCTAssertFalse(
            VoiceCaptureContinuityPolicy.shouldResumeCapture(
                continuationRequested: false,
                phase: .interrupted,
                isBackgrounded: false,
                recorderIsLive: false
            )
        )
        XCTAssertFalse(
            VoiceCaptureContinuityPolicy.shouldResumeCapture(
                continuationRequested: true,
                phase: .interrupted,
                isBackgrounded: true,
                recorderIsLive: false
            )
        )
        XCTAssertFalse(
            VoiceCaptureContinuityPolicy.shouldResumeCapture(
                continuationRequested: true,
                phase: .recording,
                isBackgrounded: false,
                recorderIsLive: true
            )
        )
    }

    func testRecoveryUIRequiresConfirmationAndCannotBeSwipeDismissed() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/App/Views/KycodeRootView.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "private struct VoiceRecordingRecoverySheet"))
        let tail = String(source[start.lowerBound...])
        let end = try XCTUnwrap(tail.range(of: "private struct DashboardHeader"))
        let sheetSource = String(tail[..<end.lowerBound])

        XCTAssertTrue(sheetSource.contains(".interactiveDismissDisabled(true)"))
        XCTAssertTrue(sheetSource.contains("¿Borrar este audio definitivamente?"))
        XCTAssertTrue(sheetSource.contains("Sí, borrar definitivamente"))
    }

    private func clearPersistedRecording() {
        if let manifest = try? VoiceRecordingPersistence.load() {
            VoiceRecordingPersistence.discard(manifest)
        }
        guard let directory = try? VoiceRecordingPersistence.recordingDirectory(),
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
              ) else { return }
        for file in files { try? FileManager.default.removeItem(at: file) }
    }

    private func makeManifest(
        segmentNames: [String],
        lastKnownDuration: TimeInterval = 0
    ) -> VoiceRecordingManifest {
        VoiceRecordingManifest(
            id: UUID().uuidString,
            windowId: "background-recording-tests",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200),
            segmentFileNames: segmentNames,
            lastKnownDuration: lastKnownDuration,
            phase: .recording
        )
    }

    private func staleWave(samples: Data) -> Data {
        var data = waveHeader(dataByteCount: 0)
        data.append(samples)
        return data
    }

    private func validWave(samples: Data) -> Data {
        var data = waveHeader(dataByteCount: UInt32(samples.count))
        data.append(samples)
        return data
    }

    private func waveHeader(dataByteCount: UInt32) -> Data {
        let sampleRate = VoiceRecordingPersistence.sampleRate
        let channels = VoiceRecordingPersistence.channels
        let bits = VoiceRecordingPersistence.bitsPerSample
        let bytesPerSample = bits / 8
        var data = Data()
        data.append(Data("RIFF".utf8))
        data.append(littleEndian(36 + dataByteCount))
        data.append(Data("WAVEfmt ".utf8))
        data.append(littleEndian(UInt32(16)))
        data.append(littleEndian(UInt16(1)))
        data.append(littleEndian(channels))
        data.append(littleEndian(sampleRate))
        data.append(littleEndian(sampleRate * UInt32(channels) * UInt32(bytesPerSample)))
        data.append(littleEndian(channels * bytesPerSample))
        data.append(littleEndian(bits))
        data.append(Data("data".utf8))
        data.append(littleEndian(dataByteCount))
        return data
    }

    private func littleEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        var littleEndian = value.littleEndian
        return withUnsafeBytes(of: &littleEndian) { Data($0) }
    }
}
