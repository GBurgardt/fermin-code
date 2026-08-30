import AVFoundation
import XCTest
@testable import KyCode

final class VoiceCapturePerformanceTests: XCTestCase {
    func testStartPlanUsesPreparedRecorderWithoutRepeatingWarmup() {
        XCTAssertEqual(
            VoiceCapturePerformancePolicy.startPlan(
                permission: .granted,
                hasPreparedRecorder: true
            ),
            .startPreparedRecorder
        )
        XCTAssertEqual(
            VoiceCapturePerformancePolicy.startPlan(
                permission: .granted,
                hasPreparedRecorder: false
            ),
            .prepareThenStart
        )
    }

    func testStartPlanKeepsPermissionPromptOutOfNormalGrantedPath() {
        XCTAssertEqual(
            VoiceCapturePerformancePolicy.startPlan(
                permission: .undetermined,
                hasPreparedRecorder: false
            ),
            .requestPermission
        )
        XCTAssertEqual(
            VoiceCapturePerformancePolicy.startPlan(
                permission: .denied,
                hasPreparedRecorder: true
            ),
            .rejectDeniedPermission
        )
    }

    func testFeedbackContractHasNoArtificialDelay() {
        XCTAssertEqual(VoiceCapturePerformancePolicy.contactFeedbackDelay, 0)
        XCTAssertEqual(VoiceCapturePerformancePolicy.recordingStateFeedbackDelay, 0)
        XCTAssertLessThanOrEqual(
            VoiceCapturePerformancePolicy.contactFeedbackDelay,
            VoiceCapturePerformancePolicy.feedbackTarget
        )
        XCTAssertLessThanOrEqual(
            VoiceCapturePerformancePolicy.recordingStateFeedbackDelay,
            VoiceCapturePerformancePolicy.feedbackTarget
        )
    }

    func testAccessibilityActivationGetsOneDebouncedFallbackHaptic() {
        XCTAssertTrue(
            VoiceCapturePerformancePolicy.shouldPlayAccessibilityFeedbackFallback(
                lastTouchDownUptime: nil,
                actionUptime: 10
            )
        )
        XCTAssertFalse(
            VoiceCapturePerformancePolicy.shouldPlayAccessibilityFeedbackFallback(
                lastTouchDownUptime: 10,
                actionUptime: 10.1
            )
        )
        XCTAssertTrue(
            VoiceCapturePerformancePolicy.shouldPlayAccessibilityFeedbackFallback(
                lastTouchDownUptime: 10,
                actionUptime: 10.31
            )
        )
    }

    func testRecorderFormatRemainsVoxtralCompatiblePCM16Mono16K() throws {
        let settings = VoiceCapturePerformancePolicy.recorderSettings
        XCTAssertEqual(settings[AVFormatIDKey] as? Int, Int(kAudioFormatLinearPCM))
        XCTAssertEqual(settings[AVSampleRateKey] as? Double, 16_000)
        XCTAssertEqual(settings[AVNumberOfChannelsKey] as? Int, 1)
        XCTAssertEqual(settings[AVLinearPCMBitDepthKey] as? Int, 16)
        XCTAssertEqual(settings[AVLinearPCMIsFloatKey] as? Bool, false)
        XCTAssertEqual(settings[AVLinearPCMIsBigEndianKey] as? Bool, false)
    }

    func testAudioPreferencesRequestLowLatencyWithoutChangingOutputFormat() {
        XCTAssertEqual(VoiceCapturePerformancePolicy.preferredIOBufferDuration, 0.005)
        XCTAssertEqual(VoiceCapturePerformancePolicy.preferredHardwareSampleRate, 48_000)
        XCTAssertEqual(VoiceCapturePerformancePolicy.outputSampleRate, 16_000)
    }

    func testAppleVoiceProcessingUsesVoiceChatSessionModeOnlyWhenEnabled() {
        XCTAssertEqual(
            VoiceCaptureProcessingPolicy.audioSessionMode(for: .off),
            .measurement
        )
        XCTAssertEqual(
            VoiceCaptureProcessingPolicy.audioSessionMode(for: .appleProcessing),
            .voiceChat
        )
        XCTAssertEqual(
            VoiceCaptureProcessingPolicy.audioSessionMode(for: .personalized),
            .voiceChat
        )
    }

    func testStartMetricsEvaluateHundredMillisecondContract() {
        let passing = VoiceCaptureStartMetrics(
            usedPreparedRecorder: true,
            preparationMilliseconds: 0,
            activationMilliseconds: 42,
            recordCallMilliseconds: 2,
            contactToRecordingMilliseconds: 78,
            actualIOBufferMilliseconds: 5,
            inputLatencyMilliseconds: 12
        )
        let failing = VoiceCaptureStartMetrics(
            usedPreparedRecorder: false,
            preparationMilliseconds: 80,
            activationMilliseconds: 250,
            recordCallMilliseconds: 4,
            contactToRecordingMilliseconds: 410,
            actualIOBufferMilliseconds: 23,
            inputLatencyMilliseconds: 45
        )

        XCTAssertTrue(passing.meetsRecordingStartTarget)
        XCTAssertFalse(failing.meetsRecordingStartTarget)
    }

    func testMinimumClipAndFinishFallbackPreserveExistingSafetyContract() {
        XCTAssertEqual(VoiceCapturePerformancePolicy.minimumRecordingDuration, 0.4)
        XCTAssertEqual(VoiceCapturePerformancePolicy.minimumRecordingBytes, 512)
        XCTAssertEqual(VoiceCapturePerformancePolicy.recorderFinishTimeout, 1.5)
    }

    func testVoiceUIHasNoAudioEngineCueOrDelayedStartHaptic() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = projectRoot
            .appendingPathComponent("Sources/App/Views/KycodeRootView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("ImmediateVoiceButtonStyle"))
        XCTAssertTrue(source.contains("handleVoiceTouchDown()"))
        XCTAssertTrue(source.contains("AppHaptics.shared.play(.voiceRecordingStart)"))
        XCTAssertFalse(source.contains("VoiceComposerCuePlayer"))
        XCTAssertFalse(source.contains("deadline: .now() + 0.045"))
        XCTAssertFalse(source.contains("deadline: .now() + 0.016"))
    }

    func testProductionCaptureUsesSampleVerifiedRecorderInsteadOfUnverifiedEngine() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = projectRoot
            .appendingPathComponent("Sources/App/AudioRecordingService.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "func startRecording("))
        let tail = String(source[start.lowerBound...])
        let end = try XCTUnwrap(tail.range(of: "func stopRecording("))
        let startSource = String(tail[..<end.lowerBound])

        XCTAssertTrue(startSource.contains("recorderProducedInitialAudio"))
        XCTAssertTrue(startSource.contains("scheduleRecorderProgressMonitor"))
        XCTAssertTrue(startSource.contains("activate(isolationMode: .off)"))
        XCTAssertFalse(startSource.contains("startVoiceProcessingCapture("))
    }

    func testRecorderLivenessContractRejectsFrozenZeroClockQuickly() {
        XCTAssertEqual(VoiceCapturePerformancePolicy.recorderMinimumLiveDuration, 0.08)
        XCTAssertEqual(VoiceCapturePerformancePolicy.recorderLivenessPollInterval, 0.04)
        XCTAssertLessThanOrEqual(VoiceCapturePerformancePolicy.recorderLivenessTimeout, 0.75)
        XCTAssertGreaterThan(
            VoiceCapturePerformancePolicy.recorderLivenessTimeout,
            VoiceCapturePerformancePolicy.recorderMinimumLiveDuration
        )
    }

    func testStopTailPaddingIsShortAndNonZero() {
        XCTAssertGreaterThan(VoiceCapturePerformancePolicy.stopTailPaddingDuration, 0.15)
        XCTAssertLessThan(VoiceCapturePerformancePolicy.stopTailPaddingDuration, 0.5)
    }

    func testVoiceCaptureFailureOffersVisibleRetryInsteadOfFrozenZeroUI() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = projectRoot
            .appendingPathComponent("Sources/App/Views/KycodeRootView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("Reintentar micrófono"))
        XCTAssertTrue(source.contains("voice-capture-retry-error"))
        XCTAssertTrue(source.contains("duration * 10"))
        XCTAssertTrue(source.contains("recording-feature-controls"))
        XCTAssertTrue(source.contains("captureTailPadding: false"))
    }

    func testFailedValidationNeverDeletesTheOnlyRecordingFile() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = projectRoot
            .appendingPathComponent("Sources/App/AudioRecordingService.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private func validateFinishedRecording"))
        let tail = String(source[start.lowerBound...])
        let end = try XCTUnwrap(tail.range(of: "private func resumeRecorderFinish"))
        let validationSource = String(tail[..<end.lowerBound])

        XCTAssertFalse(validationSource.contains("removeItem"))
        XCTAssertTrue(validationSource.contains("conservo bytes para recuperación"))
    }
}
