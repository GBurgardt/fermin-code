import AVFoundation
import Foundation
import os

/// The latency contract for voice capture. Keeping these values in one place
/// makes the performance choices reviewable and lets tests guard against a
/// future regression that quietly reintroduces delayed feedback.
struct VoiceCapturePerformancePolicy: Equatable, Sendable {
    static let contactFeedbackDelay: TimeInterval = 0
    static let recordingStateFeedbackDelay: TimeInterval = 0
    static let feedbackTarget: TimeInterval = 0.050
    static let recordingStartTarget: TimeInterval = 0.100
    static let preferredIOBufferDuration: TimeInterval = 0.005
    static let preferredHardwareSampleRate: Double = 48_000
    static let outputSampleRate: Double = 16_000
    static let minimumRecordingDuration: TimeInterval = 0.4
    static let minimumRecordingBytes = 512
    static let recorderFinishTimeout: TimeInterval = 1.5
    static let recorderLivenessTimeout: TimeInterval = 0.65
    static let recorderMinimumLiveDuration: TimeInterval = 0.08
    static let recorderLivenessPollInterval: TimeInterval = 0.04
    static let stopTailPaddingDuration: TimeInterval = 0.28
    static let accessibilityFeedbackFallbackWindow: TimeInterval = 0.30

    enum StartPlan: Equatable, Sendable {
        case rejectDeniedPermission
        case requestPermission
        case startPreparedRecorder
        case prepareThenStart
    }

    enum Permission: Equatable, Sendable {
        case granted
        case undetermined
        case denied
    }

    static func startPlan(permission: Permission, hasPreparedRecorder: Bool) -> StartPlan {
        switch permission {
        case .denied:
            return .rejectDeniedPermission
        case .undetermined:
            return .requestPermission
        case .granted:
            return hasPreparedRecorder ? .startPreparedRecorder : .prepareThenStart
        }
    }

    static func shouldPlayAccessibilityFeedbackFallback(
        lastTouchDownUptime: TimeInterval?,
        actionUptime: TimeInterval
    ) -> Bool {
        guard let lastTouchDownUptime else { return true }
        return actionUptime - lastTouchDownUptime > accessibilityFeedbackFallbackWindow
    }

    static var recorderSettings: [String: Any] {
        [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: outputSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }
}

enum VoiceCaptureProcessingPolicy {
    static func isolationMode() -> VoiceIsolationMode {
        VoiceIsolationPreferences.loadMode()
    }

    static func audioSessionMode(for isolationMode: VoiceIsolationMode) -> AVAudioSession.Mode {
        isolationMode.usesAppleVoiceProcessing ? .voiceChat : .measurement
    }
}

struct VoiceCaptureStartMetrics: Equatable, Sendable {
    let usedPreparedRecorder: Bool
    let preparationMilliseconds: Double
    let activationMilliseconds: Double
    let recordCallMilliseconds: Double
    let contactToRecordingMilliseconds: Double
    let actualIOBufferMilliseconds: Double
    let inputLatencyMilliseconds: Double

    var meetsRecordingStartTarget: Bool {
        contactToRecordingMilliseconds <= VoiceCapturePerformancePolicy.recordingStartTarget * 1_000
    }
}

private struct VoiceAudioSessionSnapshot: Equatable, Sendable {
    let sampleRate: Double
    let ioBufferDuration: TimeInterval
    let inputLatency: TimeInterval
    let routeSummary: String
}

/// AVAudioSession configuration and activation may block while Core Audio
/// negotiates a route. An actor keeps that work serial without occupying the
/// main actor that must paint the pressed/recording UI.
private actor VoiceAudioSessionController {
    private var configurationIsWarm = false
    private var configuredSessionMode: AVAudioSession.Mode?

    func prepare(isolationMode: VoiceIsolationMode) throws {
        let session = AVAudioSession.sharedInstance()
        let options = recordingOptions
        let sessionMode = VoiceCaptureProcessingPolicy.audioSessionMode(for: isolationMode)
        let needsCategoryUpdate = !configurationIsWarm
            || session.category != .playAndRecord
            || session.mode != sessionMode
            || session.categoryOptions != options

        if needsCategoryUpdate {
            try session.setCategory(.playAndRecord, mode: sessionMode, options: options)
        }

        if abs(session.preferredSampleRate - VoiceCapturePerformancePolicy.preferredHardwareSampleRate) > 1 {
            try session.setPreferredSampleRate(VoiceCapturePerformancePolicy.preferredHardwareSampleRate)
        }
        if abs(session.preferredIOBufferDuration - VoiceCapturePerformancePolicy.preferredIOBufferDuration) > 0.000_5 {
            try session.setPreferredIOBufferDuration(VoiceCapturePerformancePolicy.preferredIOBufferDuration)
        }

        // This is best effort: recording must still work on hardware that
        // declines the preference, while the contact haptic already happened
        // before the session became active.
        try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        configurationIsWarm = true
        configuredSessionMode = sessionMode
    }

    func activate(isolationMode: VoiceIsolationMode) throws -> VoiceAudioSessionSnapshot {
        try prepare(isolationMode: isolationMode)
        let session = AVAudioSession.sharedInstance()
        try session.setActive(true)
        return VoiceAudioSessionSnapshot(
            sampleRate: session.sampleRate,
            ioBufferDuration: session.ioBufferDuration,
            inputLatency: session.inputLatency,
            routeSummary: session.currentRoute.inputs
                .map { "\($0.portType.rawValue):\($0.portName)" }
                .joined(separator: ",")
        )
    }

    func deactivate() throws {
        try AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    func invalidateConfiguration() {
        configurationIsWarm = false
        configuredSessionMode = nil
    }

    private var recordingOptions: AVAudioSession.CategoryOptions {
#if compiler(>=6.2)
        [.allowBluetoothHFP]
#else
        [.allowBluetooth]
#endif
    }
}

private enum VoiceRecorderPreparationError: Error {
    case prepareFailed
}

/// File creation and `prepareToRecord()` are deliberately kept away from the
/// main actor. Apple documents that preflighting the recorder is the path to a
/// faster subsequent `record()` call.
private actor VoiceRecorderPreparationWorker {
    func makePreparedRecorder(url: URL) throws -> AVAudioRecorder {
        let recorder = try AVAudioRecorder(
            url: url,
            settings: VoiceCapturePerformancePolicy.recorderSettings
        )
        recorder.isMeteringEnabled = true
        guard recorder.prepareToRecord() else {
            throw VoiceRecorderPreparationError.prepareFailed
        }
        return recorder
    }
}

/// Captures the processed microphone uplink produced by Apple's Voice-
/// Processing I/O audio unit. The original AVAudioRecorder path remains the
/// fallback whenever the engine or the current route cannot enable it.
private final class VoiceProcessingEngineRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let outputURL: URL
    private let onFatalError: @Sendable (String) -> Void
    private let metricsLock = NSLock()
    private let writerQueue = DispatchQueue(
        label: "dev.fermincode.mobile.voice-processing-wav-writer",
        qos: .userInitiated
    )
    private var outputHandle: FileHandle?
    private var converter: AVAudioConverter?
    private var writtenFrames: AVAudioFramePosition = 0
    private var durableDataBytes: UInt64 = 0
    private var lastCheckpointBytes: UInt64 = 0
    private var latestLevel: Float = 0
    private var isAcceptingBuffers = false
    private var writeFailureReported = false
    private(set) var isRecording = false

    init(outputURL: URL, onFatalError: @escaping @Sendable (String) -> Void) {
        self.outputURL = outputURL
        self.onFatalError = onFatalError
    }

    var currentTime: TimeInterval {
        metricsLock.lock()
        defer { metricsLock.unlock() }
        return Double(writtenFrames) / VoiceCapturePerformancePolicy.outputSampleRate
    }

    var currentLevel: Float {
        metricsLock.lock()
        defer { metricsLock.unlock() }
        return latestLevel
    }

    func prepare() throws {
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        input.isVoiceProcessingAGCEnabled = true

        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: VoiceCapturePerformancePolicy.outputSampleRate,
                channels: 1,
                interleaved: true
              ),
              let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioRecordingService.RecordingError.cannotConfigureSession
        }

        try VoiceRecordingPersistence.createCrashRecoverableWAV(at: outputURL)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        try outputHandle.seekToEnd()
        self.outputHandle = outputHandle
        self.converter = converter

        input.installTap(
            onBus: 0,
            bufferSize: 1_024,
            format: inputFormat
        ) { [weak self] buffer, _ in
            self?.consume(buffer, targetFormat: targetFormat)
        }
        engine.prepare()
    }

    func start() throws {
        metricsLock.lock()
        isAcceptingBuffers = true
        metricsLock.unlock()
        try engine.start()
        isRecording = true
    }

    func stop() {
        guard outputHandle != nil || isRecording else { return }
        metricsLock.lock()
        isAcceptingBuffers = false
        metricsLock.unlock()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        writerQueue.sync {
            guard let outputHandle else { return }
            do {
                try VoiceRecordingPersistence.checkpointWAV(
                    outputHandle,
                    dataByteCount: durableDataBytes
                )
                try outputHandle.close()
            } catch {
                reportWriteFailure(error)
                try? outputHandle.close()
            }
            self.outputHandle = nil
        }
        converter = nil
        isRecording = false
    }

    private func consume(_ inputBuffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) {
        metricsLock.lock()
        let accepting = isAcceptingBuffers
        metricsLock.unlock()
        guard accepting, let converter else { return }
        let ratio = targetFormat.sampleRate / inputBuffer.format.sampleRate
        let capacity = AVAudioFrameCount(max(1, ceil(Double(inputBuffer.frameLength) * ratio) + 8))
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: capacity
        ) else { return }

        var conversionError: NSError?
        var suppliedInput = false
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }

        guard status != .error, conversionError == nil else {
            onFatalError(conversionError?.localizedDescription ?? "Falló el procesamiento de voz de Apple.")
            return
        }
        guard outputBuffer.frameLength > 0,
              let samples = outputBuffer.int16ChannelData?.pointee else { return }

        // Copy out of Core Audio's realtime buffer before returning from the
        // tap. File append/checkpoint work stays on a dedicated serial queue.
        let sampleByteCount = Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size
        let payload = Data(bytes: samples, count: sampleByteCount)
        let level = Self.normalizedLevel(from: outputBuffer)
        metricsLock.lock()
        writtenFrames += AVAudioFramePosition(outputBuffer.frameLength)
        latestLevel = level
        metricsLock.unlock()

        writerQueue.async { [weak self] in
            guard let self, let outputHandle = self.outputHandle else { return }
            do {
                try outputHandle.write(contentsOf: payload)
                self.durableDataBytes += UInt64(payload.count)
                let checkpointInterval = VoiceRecordingPersistence.bytesPerSecond / 2
                if self.durableDataBytes - self.lastCheckpointBytes >= checkpointInterval {
                    try VoiceRecordingPersistence.checkpointWAV(
                        outputHandle,
                        dataByteCount: self.durableDataBytes
                    )
                    self.lastCheckpointBytes = self.durableDataBytes
                }
            } catch {
                self.reportWriteFailure(error)
            }
        }
    }

    private func reportWriteFailure(_ error: Error) {
        guard !writeFailureReported else { return }
        writeFailureReported = true
        onFatalError("No pude guardar un bloque del audio: \(error.localizedDescription)")
    }

    private static func normalizedLevel(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.int16ChannelData?.pointee else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Double = 0
        for index in 0..<count {
            let normalized = Double(channel[index]) / Double(Int16.max)
            sum += normalized * normalized
        }
        let rms = sqrt(sum / Double(count))
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return Float(max(0, min(1, (decibels + 50) / 50)))
    }
}

@MainActor
final class AudioRecordingService: NSObject, AVAudioRecorderDelegate {
    enum RecordingError: LocalizedError, Sendable {
        case microphoneDenied
        case cannotConfigureSession
        case cannotStartRecording
        case cannotPersistRecording
        case noRecordingAvailable

        var errorDescription: String? {
            switch self {
            case .microphoneDenied:
                return "Necesito acceso al micrófono para grabar."
            case .cannotConfigureSession:
                return "No pude preparar el micrófono."
            case .cannotStartRecording:
                return "El micrófono no empezó a entregar audio. Tocá Reintentar."
            case .cannotPersistRecording:
                return "No pude preparar el almacenamiento seguro de la grabación."
            case .noRecordingAvailable:
                return "No encontré una grabación válida."
            }
        }
    }

    private struct PreparedRecording: @unchecked Sendable {
        let recorder: AVAudioRecorder
        let outputURL: URL
        let preparationMilliseconds: Double
    }

    private enum PreparationResult: @unchecked Sendable {
        case ready(PreparedRecording)
        case failed(RecordingError, String)
        case cancelled
    }

    private static let performanceLog = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.fermincode.mobile",
        category: .pointsOfInterest
    )

    private let sessionController = VoiceAudioSessionController()
    private let preparationWorker = VoiceRecorderPreparationWorker()

    private var recorder: AVAudioRecorder?
    private var voiceProcessingRecorder: VoiceProcessingEngineRecorder?
    private var preparedRecording: PreparedRecording?
    private var preparationTask: Task<PreparationResult, Never>?
    private var preparationID: UUID?
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private var finishFallbackTask: Task<Void, Never>?
    private var finishOperationID: UUID?
    private var captureHealthTask: Task<Void, Never>?

    private(set) var activeRecordingURL: URL?
    private(set) var lastError: RecordingError?
    private(set) var lastStartMetrics: VoiceCaptureStartMetrics?
    var onUnexpectedFinish: ((Bool) -> Void)?
    var onFatalRecordingError: ((String) -> Void)?

    var permission: VoiceCapturePerformancePolicy.Permission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return .granted
        case .undetermined:
            return .undetermined
        case .denied:
            return .denied
        @unknown default:
            return .denied
        }
    }

    var hasPreparedRecorder: Bool {
        preparedRecording != nil
    }

    var startPlan: VoiceCapturePerformancePolicy.StartPlan {
        VoiceCapturePerformancePolicy.startPlan(
            permission: permission,
            hasPreparedRecorder: hasPreparedRecorder
        )
    }

    var isRecording: Bool {
        (recorder?.isRecording ?? false) || (voiceProcessingRecorder?.isRecording ?? false)
    }

    var hasActiveRecorder: Bool {
        (recorder != nil || voiceProcessingRecorder != nil) && activeRecordingURL != nil
    }

    var currentTime: TimeInterval {
        voiceProcessingRecorder?.currentTime ?? recorder?.currentTime ?? 0
    }

    var currentLevel: Float {
        if let voiceProcessingRecorder, voiceProcessingRecorder.isRecording {
            return voiceProcessingRecorder.currentLevel
        }
        guard let recorder, recorder.isRecording else { return 0 }
        recorder.updateMeters()
        let decibels = recorder.averagePower(forChannel: 0)
        return max(0, min(1, (decibels + 50) / 50))
    }

    func requestPermissionIfNeeded() async -> Bool {
        switch permission {
        case .granted:
            return true
        case .denied:
            lastError = .microphoneDenied
            return false
        case .undetermined:
            log("Solicitando permiso de micrófono")
            let granted = await AVAudioApplication.requestRecordPermission()
            log("Resultado del prompt de micrófono: granted=\(granted)")
            if !granted {
                lastError = .microphoneDenied
            }
            return granted
        }
    }

    /// Warms category/preferences, creates the file, and prepares the recorder,
    /// but deliberately does not activate the session or capture the mic.
    @discardableResult
    func prepareForRecordingIfAuthorized() async -> Bool {
        guard permission == .granted, !isRecording else { return false }
        if preparedRecording != nil { return true }

        if let preparationTask, let preparationID {
            return await finishPreparation(id: preparationID, task: preparationTask)
        }

        let id = UUID()
        let outputURL: URL
        do {
            outputURL = try makeRecordingURL()
        } catch {
            lastError = .cannotPersistRecording
            log("No pude crear el segmento durable: \(error)", level: .error)
            return false
        }
        let sessionController = self.sessionController
        let preparationWorker = self.preparationWorker
        let isolationMode = VoiceCaptureProcessingPolicy.isolationMode()
        let task = Task<PreparationResult, Never> {
            let startedAt = ProcessInfo.processInfo.systemUptime
            do {
                try await sessionController.prepare(isolationMode: isolationMode)
                try Task.checkCancellation()
                let recorder = try await preparationWorker.makePreparedRecorder(url: outputURL)
                try Task.checkCancellation()
                return .ready(
                    PreparedRecording(
                        recorder: recorder,
                        outputURL: outputURL,
                        preparationMilliseconds: (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
                    )
                )
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: outputURL)
                return .cancelled
            } catch let error as AVError {
                try? FileManager.default.removeItem(at: outputURL)
                return .failed(.cannotConfigureSession, error.localizedDescription)
            } catch {
                try? FileManager.default.removeItem(at: outputURL)
                return .failed(.cannotStartRecording, error.localizedDescription)
            }
        }

        preparationID = id
        preparationTask = task
        return await finishPreparation(id: id, task: task)
    }

    func startRecording(
        interactionStartedAt: TimeInterval? = nil,
        recordingWillStart: ((URL) throws -> Void)? = nil
    ) async -> Bool {
        guard !isRecording else { return true }

        lastError = nil
        lastStartMetrics = nil
        let contactUptime = interactionStartedAt ?? ProcessInfo.processInfo.systemUptime
        let signpostID = OSSignpostID(log: Self.performanceLog)
        os_signpost(
            .begin,
            log: Self.performanceLog,
            name: "VoiceCaptureStart",
            signpostID: signpostID
        )

        guard await requestPermissionIfNeeded() else {
            endStartSignpost(signpostID, outcome: "permission-denied")
            return false
        }
        guard !Task.isCancelled else {
            endStartSignpost(signpostID, outcome: "cancelled")
            return false
        }

        let usedPreparedRecorder = preparedRecording != nil
        if preparedRecording == nil {
            _ = await prepareForRecordingIfAuthorized()
        }
        guard let preparedRecording else {
            if lastError == nil { lastError = .cannotStartRecording }
            endStartSignpost(signpostID, outcome: "prepare-failed")
            return false
        }
        self.preparedRecording = nil

        // AVAudioRecorder is the production capture backend on both iPhone
        // and iPad. The audio-session mode still applies Apple's voice
        // processing when requested, but we do not trust AVAudioEngine merely
        // reporting `isRunning`: on affected iPhones its input tap can deliver
        // zero frames forever while the system microphone indicator remains
        // active. AVAudioRecorder also gives us a clock that can be verified
        // before the state owner publishes `.recording`.
        let isolationMode = VoiceCaptureProcessingPolicy.isolationMode()
        let activationStartedAt = ProcessInfo.processInfo.systemUptime
        var activePreparedRecording = preparedRecording
        do {
            var snapshot = try await sessionController.activate(isolationMode: isolationMode)
            let activationMilliseconds = (ProcessInfo.processInfo.systemUptime - activationStartedAt) * 1_000

            guard !Task.isCancelled else {
                discardPreparedRecording(preparedRecording)
                try? await sessionController.deactivate()
                endStartSignpost(signpostID, outcome: "cancelled")
                return false
            }

            activePreparedRecording.recorder.delegate = self
            do {
                try recordingWillStart?(activePreparedRecording.outputURL)
            } catch {
                throw RecordingError.cannotPersistRecording
            }
            let recordStartedAt = ProcessInfo.processInfo.systemUptime
            guard activePreparedRecording.recorder.record() else {
                throw RecordingError.cannotStartRecording
            }
            if !(await recorderProducedInitialAudio(activePreparedRecording.recorder)) {
                log(
                    "AVAudioRecorder no avanzó después del primer inicio; reinicio la sesión una vez con la ruta estable.",
                    level: .error
                )
                activePreparedRecording.recorder.delegate = nil
                activePreparedRecording.recorder.stop()
                activePreparedRecording.recorder.deleteRecording()
                try? FileManager.default.removeItem(at: activePreparedRecording.outputURL)
                try? await sessionController.deactivate()
                await sessionController.invalidateConfiguration()

                snapshot = try await sessionController.activate(isolationMode: .off)
                let retryRecorder = try await preparationWorker.makePreparedRecorder(
                    url: activePreparedRecording.outputURL
                )
                retryRecorder.delegate = self
                try VoiceRecordingPersistence.protectOpenSegment(
                    at: activePreparedRecording.outputURL
                )
                guard retryRecorder.record(),
                      await recorderProducedInitialAudio(retryRecorder) else {
                    retryRecorder.delegate = nil
                    retryRecorder.stop()
                    throw RecordingError.cannotStartRecording
                }
                activePreparedRecording = PreparedRecording(
                    recorder: retryRecorder,
                    outputURL: activePreparedRecording.outputURL,
                    preparationMilliseconds: activePreparedRecording.preparationMilliseconds
                )
                log("Reintento estable confirmado: el reloj del micrófono avanza.")
            }
            let recordCallMilliseconds = (ProcessInfo.processInfo.systemUptime - recordStartedAt) * 1_000

            recorder = activePreparedRecording.recorder
            activeRecordingURL = activePreparedRecording.outputURL
            scheduleRecorderProgressMonitor(activePreparedRecording.recorder)
            let contactToRecordingMilliseconds = (
                ProcessInfo.processInfo.systemUptime - contactUptime
            ) * 1_000
            let metrics = VoiceCaptureStartMetrics(
                usedPreparedRecorder: usedPreparedRecorder,
                preparationMilliseconds: usedPreparedRecorder ? 0 : activePreparedRecording.preparationMilliseconds,
                activationMilliseconds: activationMilliseconds,
                recordCallMilliseconds: recordCallMilliseconds,
                contactToRecordingMilliseconds: contactToRecordingMilliseconds,
                actualIOBufferMilliseconds: snapshot.ioBufferDuration * 1_000,
                inputLatencyMilliseconds: snapshot.inputLatency * 1_000
            )
            lastStartMetrics = metrics
            log(
                String(
                    format: "Inicio real total=%.1fms prepare=%.1fms activate=%.1fms record=%.1fms warm=%@ io=%.1fms input=%.1fms rate=%.0f route=%@ target=%@",
                    metrics.contactToRecordingMilliseconds,
                    metrics.preparationMilliseconds,
                    metrics.activationMilliseconds,
                    metrics.recordCallMilliseconds,
                    metrics.usedPreparedRecorder ? "sí" : "no",
                    metrics.actualIOBufferMilliseconds,
                    metrics.inputLatencyMilliseconds,
                    snapshot.sampleRate,
                    snapshot.routeSummary,
                    metrics.meetsRecordingStartTarget ? "pass" : "measure-on-device"
                )
            )
            endStartSignpost(signpostID, outcome: "recording")
            return true
        } catch let error as RecordingError {
            lastError = error
            discardPreparedRecording(activePreparedRecording)
            try? await sessionController.deactivate()
            log("No pude iniciar la grabación: \(error.localizedDescription)", level: .error)
            endStartSignpost(signpostID, outcome: "record-failed")
            return false
        } catch {
            lastError = .cannotConfigureSession
            discardPreparedRecording(activePreparedRecording)
            try? await sessionController.deactivate()
            log("No pude configurar AVAudioSession: \(error)", level: .error)
            endStartSignpost(signpostID, outcome: "session-failed")
            return false
        }
    }

    func stopRecording(prepareNext: Bool = true) async -> URL? {
        captureHealthTask?.cancel()
        captureHealthTask = nil
        if let voiceProcessingRecorder, let outputURL = activeRecordingURL {
            let duration = voiceProcessingRecorder.currentTime
            voiceProcessingRecorder.stop()
            self.voiceProcessingRecorder = nil
            activeRecordingURL = nil
            try? await sessionController.deactivate()
            return validateFinishedRecording(
                at: outputURL,
                duration: duration,
                prepareNext: prepareNext
            )
        }

        guard let recorder, let outputURL = activeRecordingURL else {
            lastError = .noRecordingAvailable
            return nil
        }

        let duration = recorder.currentTime
        let operationID = UUID()
        finishOperationID = operationID
        finishFallbackTask?.cancel()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            finishContinuation = continuation
            recorder.stop()
            finishFallbackTask = Task { @MainActor [weak self] in
                try? await Task.sleep(
                    for: .seconds(VoiceCapturePerformancePolicy.recorderFinishTimeout)
                )
                guard !Task.isCancelled else { return }
                self?.resumeRecorderFinish(operationID: operationID)
            }
        }
        finishFallbackTask?.cancel()
        finishFallbackTask = nil
        finishOperationID = nil
        self.recorder = nil
        self.activeRecordingURL = nil
        try? await sessionController.deactivate()

        return validateFinishedRecording(
            at: outputURL,
            duration: duration,
            prepareNext: prepareNext
        )
    }

    func cancelRecording(prepareNext: Bool = true) {
        captureHealthTask?.cancel()
        captureHealthTask = nil
        finishFallbackTask?.cancel()
        finishFallbackTask = nil
        resumeRecorderFinish(operationID: finishOperationID)
        recorder?.stop()
        recorder = nil
        voiceProcessingRecorder?.stop()
        voiceProcessingRecorder = nil
        if let activeRecordingURL {
            try? FileManager.default.removeItem(at: activeRecordingURL)
            log("Grabación cancelada: \(activeRecordingURL.lastPathComponent)")
        }
        activeRecordingURL = nil
        Task {
            try? await sessionController.deactivate()
            if prepareNext {
                _ = await prepareForRecordingIfAuthorized()
            }
        }
    }

    func cancelPendingStart() {
        preparationTask?.cancel()
    }

    /// Media Services reset invalidates AVAudioRecorder itself. Keep the file
    /// untouched so the owner can repair its WAV header on the next pass.
    @discardableResult
    func abandonActiveRecordingAfterMediaServicesReset() -> URL? {
        captureHealthTask?.cancel()
        captureHealthTask = nil
        finishFallbackTask?.cancel()
        finishFallbackTask = nil
        resumeRecorderFinish(operationID: finishOperationID)
        let url = activeRecordingURL
        recorder = nil
        voiceProcessingRecorder?.stop()
        voiceProcessingRecorder = nil
        activeRecordingURL = nil
        invalidatePreparation(reason: "media services reset")
        return url
    }

    func invalidatePreparation(reason: String) {
        preparationTask?.cancel()
        preparationTask = nil
        preparationID = nil
        if let preparedRecording {
            discardPreparedRecording(preparedRecording)
            self.preparedRecording = nil
        }
        Task {
            await sessionController.invalidateConfiguration()
        }
        log("Preparación invalidada: \(reason)")
    }

    func deleteTemporaryFile(at url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
        log("Archivo temporal eliminado: \(url.lastPathComponent)")
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(
        _ recorder: AVAudioRecorder,
        error: Swift.Error?
    ) {
        guard let error else { return }
        LoggingService.logToFile(level: .error, message: "[VoiceRecorder] Encode error: \(error)")
        NSLog("%@", "[VoiceRecorder] Encode error: \(error)")
        Task { @MainActor [weak self] in
            self?.onFatalRecordingError?(error.localizedDescription)
        }
    }

    nonisolated func audioRecorderDidFinishRecording(
        _ recorder: AVAudioRecorder,
        successfully flag: Bool
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.log("AVAudioRecorder terminó success=\(flag)")
            self.resumeRecorderFinish(operationID: self.finishOperationID)
            self.onUnexpectedFinish?(flag)
        }
    }

    private func finishPreparation(
        id: UUID,
        task: Task<PreparationResult, Never>
    ) async -> Bool {
        let result = await task.value

        // Multiple callers can await the same warm-up. The first installs it;
        // later callers should observe that same installed recorder, not delete it.
        if preparationID != id {
            if case let .ready(prepared) = result,
               preparedRecording?.outputURL == prepared.outputURL {
                return true
            }
            if case let .ready(prepared) = result {
                discardPreparedRecording(prepared)
            }
            return false
        }

        preparationTask = nil
        preparationID = nil
        switch result {
        case let .ready(prepared):
            prepared.recorder.delegate = self
            preparedRecording = prepared
            log(String(format: "Micrófono precargado en %.1fms", prepared.preparationMilliseconds))
            return true
        case let .failed(error, detail):
            lastError = error
            log("No pude precargar el micrófono: \(detail)", level: .error)
            return false
        case .cancelled:
            return false
        }
    }

    private func startVoiceProcessingCapture(
        preparedRecording: PreparedRecording,
        isolationMode: VoiceIsolationMode,
        contactUptime: TimeInterval,
        recordingWillStart: ((URL) throws -> Void)?,
        signpostID: OSSignpostID
    ) async -> Bool {
        let activationStartedAt = ProcessInfo.processInfo.systemUptime
        let snapshot: VoiceAudioSessionSnapshot
        do {
            snapshot = try await sessionController.activate(isolationMode: isolationMode)
        } catch {
            log("Voice Processing no pudo activar la sesión: \(error)", level: .error)
            return await startRecorderFallback(
                outputURL: preparedRecording.outputURL,
                contactUptime: contactUptime,
                recordingWillStart: recordingWillStart,
                persistenceWasRegistered: false,
                signpostID: signpostID,
                preparationStartedAt: activationStartedAt
            )
        }
        let activationMilliseconds = (ProcessInfo.processInfo.systemUptime - activationStartedAt) * 1_000

        // The warm AVAudioRecorder owns this path. Release it before the
        // engine creates its durable WAV at exactly the same manifest URL.
        discardPreparedRecording(preparedRecording)
        let processor = VoiceProcessingEngineRecorder(
            outputURL: preparedRecording.outputURL
        ) { [weak self] message in
            Task { @MainActor in self?.onFatalRecordingError?(message) }
        }
        do {
            try processor.prepare()
        } catch {
            processor.stop()
            log("Voice Processing no está disponible en esta ruta; uso recorder base: \(error)")
            return await startRecorderFallback(
                outputURL: preparedRecording.outputURL,
                contactUptime: contactUptime,
                recordingWillStart: recordingWillStart,
                persistenceWasRegistered: false,
                signpostID: signpostID,
                preparationStartedAt: activationStartedAt
            )
        }

        do {
            try recordingWillStart?(preparedRecording.outputURL)
        } catch {
            processor.stop()
            lastError = .cannotPersistRecording
            try? await sessionController.deactivate()
            endStartSignpost(signpostID, outcome: "persistence-failed")
            return false
        }

        let recordStartedAt = ProcessInfo.processInfo.systemUptime
        do {
            try processor.start()
        } catch {
            processor.stop()
            log("Voice Processing no pudo iniciar; conservo manifest y uso recorder base: \(error)")
            return await startRecorderFallback(
                outputURL: preparedRecording.outputURL,
                contactUptime: contactUptime,
                recordingWillStart: recordingWillStart,
                persistenceWasRegistered: true,
                signpostID: signpostID,
                preparationStartedAt: activationStartedAt
            )
        }

        let recordCallMilliseconds = (ProcessInfo.processInfo.systemUptime - recordStartedAt) * 1_000
        voiceProcessingRecorder = processor
        activeRecordingURL = preparedRecording.outputURL
        scheduleVoiceProcessingHealthCheck(
            processor: processor,
            contactUptime: contactUptime,
            recordingWillStart: recordingWillStart
        )
        let metrics = VoiceCaptureStartMetrics(
            usedPreparedRecorder: false,
            preparationMilliseconds: preparedRecording.preparationMilliseconds,
            activationMilliseconds: activationMilliseconds,
            recordCallMilliseconds: recordCallMilliseconds,
            contactToRecordingMilliseconds: (ProcessInfo.processInfo.systemUptime - contactUptime) * 1_000,
            actualIOBufferMilliseconds: snapshot.ioBufferDuration * 1_000,
            inputLatencyMilliseconds: snapshot.inputLatency * 1_000
        )
        lastStartMetrics = metrics
        log(
            String(
                format: "Inicio Voice Processing total=%.1fms activate=%.1fms record=%.1fms io=%.1fms input=%.1fms rate=%.0f route=%@",
                metrics.contactToRecordingMilliseconds,
                metrics.activationMilliseconds,
                metrics.recordCallMilliseconds,
                metrics.actualIOBufferMilliseconds,
                metrics.inputLatencyMilliseconds,
                snapshot.sampleRate,
                snapshot.routeSummary
            )
        )
        endStartSignpost(signpostID, outcome: "voice-processing")
        return true
    }

    private func startRecorderFallback(
        outputURL: URL,
        contactUptime: TimeInterval,
        recordingWillStart: ((URL) throws -> Void)?,
        persistenceWasRegistered: Bool,
        signpostID: OSSignpostID,
        preparationStartedAt: TimeInterval,
        shouldEndSignpost: Bool = true
    ) async -> Bool {
        do {
            _ = try await sessionController.activate(isolationMode: .off)
            try? FileManager.default.removeItem(at: outputURL)
            let fallback = try await preparationWorker.makePreparedRecorder(url: outputURL)
            fallback.delegate = self
            if !persistenceWasRegistered {
                try recordingWillStart?(outputURL)
            }
            let recordStartedAt = ProcessInfo.processInfo.systemUptime
            guard fallback.record() else {
                throw RecordingError.cannotStartRecording
            }
            recorder = fallback
            activeRecordingURL = outputURL
            let metrics = VoiceCaptureStartMetrics(
                usedPreparedRecorder: false,
                preparationMilliseconds: (recordStartedAt - preparationStartedAt) * 1_000,
                activationMilliseconds: 0,
                recordCallMilliseconds: (ProcessInfo.processInfo.systemUptime - recordStartedAt) * 1_000,
                contactToRecordingMilliseconds: (ProcessInfo.processInfo.systemUptime - contactUptime) * 1_000,
                actualIOBufferMilliseconds: AVAudioSession.sharedInstance().ioBufferDuration * 1_000,
                inputLatencyMilliseconds: AVAudioSession.sharedInstance().inputLatency * 1_000
            )
            lastStartMetrics = metrics
            log("Fallback AVAudioRecorder activo; el audio durable conserva el mismo manifest.")
            if shouldEndSignpost {
                endStartSignpost(signpostID, outcome: "recorder-fallback")
            }
            return true
        } catch let error as RecordingError {
            lastError = error
        } catch {
            lastError = .cannotStartRecording
            log("También falló el recorder de respaldo: \(error)", level: .error)
        }
        try? await sessionController.deactivate()
        if shouldEndSignpost {
            endStartSignpost(signpostID, outcome: "fallback-failed")
        }
        return false
    }

    private func scheduleVoiceProcessingHealthCheck(
        processor: VoiceProcessingEngineRecorder,
        contactUptime: TimeInterval,
        recordingWillStart: ((URL) throws -> Void)?
    ) {
        captureHealthTask?.cancel()
        captureHealthTask = Task { @MainActor [weak self, weak processor] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled,
                  let self,
                  let processor,
                  self.voiceProcessingRecorder === processor,
                  processor.isRecording,
                  processor.currentTime < 0.10 else { return }

            self.log(
                "Voice Processing no produjo muestras en 900ms; conservo el segmento y cambio al recorder estable.",
                level: .error
            )
            processor.stop()
            self.voiceProcessingRecorder = nil
            self.activeRecordingURL = nil

            let fallbackURL: URL
            do {
                fallbackURL = try self.makeRecordingURL()
            } catch {
                self.lastError = .cannotPersistRecording
                self.onFatalRecordingError?("No pude crear el segmento de respaldo.")
                return
            }
            let fallbackStarted = await self.startRecorderFallback(
                outputURL: fallbackURL,
                contactUptime: contactUptime,
                recordingWillStart: recordingWillStart,
                persistenceWasRegistered: false,
                signpostID: OSSignpostID(log: Self.performanceLog),
                preparationStartedAt: ProcessInfo.processInfo.systemUptime,
                shouldEndSignpost: false
            )
            if !fallbackStarted {
                self.onFatalRecordingError?(
                    "El procesamiento dejó de entregar audio y también falló el grabador de respaldo."
                )
            }
        }
    }

    /// `record()` returning true only means Core Audio accepted the request.
    /// It does not guarantee that the recorder clock or file writer is alive.
    /// Wait briefly for observable progress before exposing recording state.
    private func recorderProducedInitialAudio(_ candidate: AVAudioRecorder) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime
            + VoiceCapturePerformancePolicy.recorderLivenessTimeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard !Task.isCancelled, candidate.isRecording else { return false }
            if candidate.currentTime >= VoiceCapturePerformancePolicy.recorderMinimumLiveDuration {
                return true
            }
            try? await Task.sleep(
                for: .seconds(VoiceCapturePerformancePolicy.recorderLivenessPollInterval)
            )
        }
        return candidate.isRecording
            && candidate.currentTime >= VoiceCapturePerformancePolicy.recorderMinimumLiveDuration
    }

    /// Detect a recorder that becomes stuck after a valid start. Two seconds
    /// without clock movement is surfaced as a real capture failure instead
    /// of leaving the composer frozen at 0:00 indefinitely.
    private func scheduleRecorderProgressMonitor(_ monitoredRecorder: AVAudioRecorder) {
        captureHealthTask?.cancel()
        captureHealthTask = Task { @MainActor [weak self, weak monitoredRecorder] in
            var previousTime = monitoredRecorder?.currentTime ?? 0
            var stagnantChecks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled,
                      let self,
                      let monitoredRecorder,
                      self.recorder === monitoredRecorder,
                      monitoredRecorder.isRecording else { return }
                let currentTime = monitoredRecorder.currentTime
                if currentTime > previousTime + 0.02 {
                    previousTime = currentTime
                    stagnantChecks = 0
                    continue
                }
                stagnantChecks += 1
                guard stagnantChecks >= 4 else { continue }
                self.lastError = .cannotStartRecording
                self.log(
                    "El reloj del grabador quedó detenido durante 2s; cierro el segmento y muestro un error recuperable.",
                    level: .error
                )
                self.onFatalRecordingError?(
                    "El micrófono dejó de entregar audio. Tocá Reintentar para abrir una captura nueva."
                )
                return
            }
        }
    }

    private func validateFinishedRecording(
        at outputURL: URL,
        duration: TimeInterval,
        prepareNext: Bool
    ) -> URL? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path)
        let byteCount = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard FileManager.default.fileExists(atPath: outputURL.path),
              duration > VoiceCapturePerformancePolicy.minimumRecordingDuration,
              byteCount > VoiceCapturePerformancePolicy.minimumRecordingBytes else {
            lastError = .noRecordingAvailable
            log(
                "Grabación todavía no validable; conservo bytes para recuperación duration=\(duration) bytes=\(byteCount)",
                level: .error
            )
            return nil
        }
        log("Grabación finalizada: \(outputURL.lastPathComponent) bytes=\(byteCount)")
        if prepareNext { scheduleNextWarmRecorder() }
        return outputURL
    }

    private func resumeRecorderFinish(operationID: UUID?) {
        guard let operationID, finishOperationID == operationID else { return }
        finishContinuation?.resume()
        finishContinuation = nil
    }

    private func discardPreparedRecording(_ prepared: PreparedRecording) {
        prepared.recorder.stop()
        prepared.recorder.deleteRecording()
        try? FileManager.default.removeItem(at: prepared.outputURL)
    }

    private func makeRecordingURL() throws -> URL {
        try VoiceRecordingPersistence.makeSegmentURL()
    }

    private func scheduleNextWarmRecorder() {
        Task { @MainActor [weak self] in
            _ = await self?.prepareForRecordingIfAuthorized()
        }
    }

    private func endStartSignpost(_ signpostID: OSSignpostID, outcome: StaticString) {
        os_signpost(
            .end,
            log: Self.performanceLog,
            name: "VoiceCaptureStart",
            signpostID: signpostID,
            "%{public}s",
            String(describing: outcome)
        )
    }

    private func log(_ message: String, level: LogLevel = .debug) {
        let line = "[VoiceRecorder] \(message)"
        LoggingService.logToFile(level: level, message: line)
        NSLog("%@", line)
    }
}
