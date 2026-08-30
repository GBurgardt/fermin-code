import AVFoundation
import Combine
import Foundation
import UIKit

struct BackgroundRecordingResult: Sendable {
    let windowId: String
    let fileURL: URL
    let duration: TimeInterval
}

struct RecoverableVoiceRecording: Identifiable, Equatable, Sendable {
    let id: String
    let windowId: String
    let createdAt: Date
    let duration: TimeInterval
    let segmentCount: Int
    let hasPlayableAudio: Bool
}

struct VoiceRecordingManifest: Codable, Equatable, Sendable {
    enum PersistedPhase: String, Codable, Sendable {
        case starting
        case recording
        case interrupted
    }

    let id: String
    let windowId: String
    let createdAt: Date
    var updatedAt: Date
    var segmentFileNames: [String]
    var lastKnownDuration: TimeInterval
    var phase: PersistedPhase
}

struct VoiceWAVInfo: Equatable, Sendable {
    let dataOffset: UInt64
    let dataByteCount: UInt64
    let duration: TimeInterval
}

enum VoiceRecordingPersistenceError: LocalizedError {
    case invalidWAV
    case incompatibleWAV
    case noRecoverableAudio
    case recordingDirectoryUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidWAV:
            return "El archivo de audio quedó incompleto y no pude repararlo."
        case .incompatibleWAV:
            return "Los segmentos de audio no tienen el mismo formato."
        case .noRecoverableAudio:
            return "No encontré audio recuperable."
        case .recordingDirectoryUnavailable:
            return "No pude preparar el almacenamiento seguro de la grabación."
        }
    }
}

/// Durable, single-recording storage. The manifest is always written before
/// AVAudioRecorder starts consuming samples, so a process death can discover
/// the segment without relying on view lifecycle callbacks.
enum VoiceRecordingPersistence {
    static let sampleRate = UInt32(VoiceCapturePerformancePolicy.outputSampleRate)
    static let channels: UInt16 = 1
    static let bitsPerSample: UInt16 = 16
    static let bytesPerSecond = UInt64(sampleRate) * UInt64(channels) * UInt64(bitsPerSample / 8)

    private static let directoryName = "ActiveVoiceRecording"
    private static let manifestFileName = "active-recording.json"
    private static let identityFileName = "active-recording-identity.json"
    private static let previewFileName = "recovery-preview.wav"

    private struct RecordingIdentity: Codable {
        let id: String
        let windowId: String
        let createdAt: Date
    }

    static func recordingDirectory() throws -> URL {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw VoiceRecordingPersistenceError.recordingDirectoryUnavailable
        }
        let directory = base.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.path
        )
        return directory
    }

    static func makeSegmentURL() throws -> URL {
        try recordingDirectory().appendingPathComponent(
            "segment-\(Int(Date().timeIntervalSince1970 * 1_000))-\(UUID().uuidString).wav"
        )
    }

    static func protectOpenSegment(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VoiceRecordingPersistenceError.recordingDirectoryUnavailable
        }
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUnlessOpen],
            ofItemAtPath: url.path
        )
    }

    static func save(_ manifest: VoiceRecordingManifest) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let identity = RecordingIdentity(
            id: manifest.id,
            windowId: manifest.windowId,
            createdAt: manifest.createdAt
        )
        // Persist the small identity sidecar first. If the process dies during
        // a later manifest replacement, orphaned segments still retain enough
        // context to be surfaced instead of silently deleted.
        try encoder.encode(identity).write(
            to: try identityURL(),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
        let data = try encoder.encode(manifest)
        try data.write(
            to: try manifestURL(),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    static func load() throws -> VoiceRecordingManifest? {
        let url = try manifestURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(VoiceRecordingManifest.self, from: data)
    }

    static func segmentURLs(for manifest: VoiceRecordingManifest) throws -> [URL] {
        let directory = try recordingDirectory()
        return manifest.segmentFileNames.map { directory.appendingPathComponent($0) }
    }

    static func recoverManifest() throws -> (
        manifest: VoiceRecordingManifest,
        duration: TimeInterval,
        hasPlayableAudio: Bool
    )? {
        var manifest: VoiceRecordingManifest
        do {
            if let loaded = try load() {
                manifest = loaded
            } else if let synthesized = try synthesizeManifestFromOrphanedSegments() {
                manifest = synthesized
            } else {
                return nil
            }
        } catch {
            guard let synthesized = try synthesizeManifestFromOrphanedSegments() else {
                throw error
            }
            manifest = synthesized
        }

        let directory = try recordingDirectory()
        var duration: TimeInterval = 0
        var hasPlayableAudio = false
        for name in manifest.segmentFileNames {
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if let info = try? repairWAV(at: url), info.dataByteCount > 0 {
                duration += info.duration
                hasPlayableAudio = true
            }
        }

        // lastKnownDuration is evidence written while recording. It must not
        // be replaced with zero merely because a decoder cannot open the WAV
        // yet; keep both the manifest and every referenced byte for repair.
        manifest.lastKnownDuration = max(manifest.lastKnownDuration, duration)
        manifest.updatedAt = Date()
        manifest.phase = .interrupted
        try save(manifest)
        return (manifest, manifest.lastKnownDuration, hasPlayableAudio)
    }

    /// Creates a canonical PCM WAV before capture begins. Every subsequent
    /// payload append therefore remains structurally discoverable after a
    /// force-quit, even if the final size checkpoint did not run.
    static func createCrashRecoverableWAV(at url: URL) throws {
        try canonicalHeader(dataByteCount: 0).write(
            to: url,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
        try protectOpenSegment(at: url)
    }

    /// Updates RIFF/data sizes in place and fsyncs the open file. The append
    /// cursor is restored so the capture writer can continue immediately.
    static func checkpointWAV(_ handle: FileHandle, dataByteCount: UInt64) throws {
        guard dataByteCount <= UInt64(UInt32.max - 36) else {
            throw VoiceRecordingPersistenceError.invalidWAV
        }
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: littleEndianData(UInt32(36 + dataByteCount)))
        try handle.seek(toOffset: 40)
        try handle.write(contentsOf: littleEndianData(UInt32(dataByteCount)))
        try handle.seekToEnd()
        try handle.synchronize()
    }

    static func repairWAV(at url: URL) throws -> VoiceWAVInfo {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        guard fileSize >= 44 else { throw VoiceRecordingPersistenceError.invalidWAV }

        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: 0)
        let header = try handle.read(upToCount: Int(min(fileSize, 256 * 1_024))) ?? Data()
        guard header.count >= 44,
              ascii(header, at: 0, count: 4) == "RIFF",
              ascii(header, at: 8, count: 4) == "WAVE" else {
            throw VoiceRecordingPersistenceError.invalidWAV
        }

        var cursor = 12
        var dataSizeOffset: Int?
        var dataOffset: Int?
        var formatIsCompatible = false
        while cursor + 8 <= header.count {
            let chunkID = ascii(header, at: cursor, count: 4)
            let declaredSize = Int(littleEndianUInt32(header, at: cursor + 4))
            let payloadOffset = cursor + 8
            if chunkID == "fmt ", payloadOffset + min(declaredSize, 16) <= header.count, declaredSize >= 16 {
                let audioFormat = littleEndianUInt16(header, at: payloadOffset)
                let channelCount = littleEndianUInt16(header, at: payloadOffset + 2)
                let fileSampleRate = littleEndianUInt32(header, at: payloadOffset + 4)
                let fileBitsPerSample = littleEndianUInt16(header, at: payloadOffset + 14)
                formatIsCompatible = audioFormat == 1
                    && channelCount == channels
                    && fileSampleRate == sampleRate
                    && fileBitsPerSample == bitsPerSample
            } else if chunkID == "data" {
                dataSizeOffset = cursor + 4
                dataOffset = payloadOffset
                break
            }

            let paddedSize = declaredSize + (declaredSize & 1)
            guard paddedSize >= 0, payloadOffset + paddedSize > cursor else { break }
            cursor = payloadOffset + paddedSize
        }

        guard formatIsCompatible,
              let dataSizeOffset,
              let dataOffset,
              UInt64(dataOffset) <= fileSize else {
            throw VoiceRecordingPersistenceError.invalidWAV
        }

        let dataByteCount = fileSize - UInt64(dataOffset)
        guard dataByteCount <= UInt64(UInt32.max), fileSize - 8 <= UInt64(UInt32.max) else {
            throw VoiceRecordingPersistenceError.invalidWAV
        }

        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: littleEndianData(UInt32(fileSize - 8)))
        try handle.seek(toOffset: UInt64(dataSizeOffset))
        try handle.write(contentsOf: littleEndianData(UInt32(dataByteCount)))
        try handle.synchronize()
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        return VoiceWAVInfo(
            dataOffset: UInt64(dataOffset),
            dataByteCount: dataByteCount,
            duration: TimeInterval(dataByteCount) / TimeInterval(bytesPerSecond)
        )
    }

    static func hasPlayableAudio(in manifest: VoiceRecordingManifest) -> Bool {
        guard let urls = try? segmentURLs(for: manifest) else { return false }
        return urls.contains { url in
            guard FileManager.default.fileExists(atPath: url.path),
                  let info = try? repairWAV(at: url) else { return false }
            return info.dataByteCount > 0
        }
    }

    static func makeFinalRecording(from manifest: VoiceRecordingManifest) throws -> BackgroundRecordingResult {
        let urls = try segmentURLs(for: manifest)
        var sources: [(URL, VoiceWAVInfo)] = []
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            // A damaged segment must never hide healthy earlier segments.
            // Skip it for this finalization attempt but leave it on disk.
            if let info = try? repairWAV(at: url), info.dataByteCount > 0 {
                sources.append((url, info))
            }
        }
        guard !sources.isEmpty else { throw VoiceRecordingPersistenceError.noRecoverableAudio }

        let totalBytes = sources.reduce(UInt64(0)) { $0 + $1.1.dataByteCount }
        guard totalBytes > 0, totalBytes <= UInt64(UInt32.max - 36) else {
            throw VoiceRecordingPersistenceError.noRecoverableAudio
        }
        let duration = TimeInterval(totalBytes) / TimeInterval(bytesPerSecond)

        if sources.count == 1 {
            return BackgroundRecordingResult(
                windowId: manifest.windowId,
                fileURL: sources[0].0,
                duration: duration
            )
        }

        let outputURL = try recordingDirectory().appendingPathComponent(
            "final-\(manifest.id)-\(UUID().uuidString).wav"
        )
        FileManager.default.createFile(
            atPath: outputURL.path,
            contents: canonicalHeader(dataByteCount: UInt32(totalBytes)),
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        let output = try FileHandle(forWritingTo: outputURL)
        do {
            try output.seekToEnd()
            for (url, info) in sources {
                let input = try FileHandle(forReadingFrom: url)
                do {
                    try input.seek(toOffset: info.dataOffset)
                    var remaining = info.dataByteCount
                    while remaining > 0 {
                        let count = Int(min(remaining, 64 * 1_024))
                        guard let chunk = try input.read(upToCount: count), !chunk.isEmpty else {
                            throw VoiceRecordingPersistenceError.invalidWAV
                        }
                        try output.write(contentsOf: chunk)
                        remaining -= UInt64(chunk.count)
                    }
                    try input.close()
                } catch {
                    try? input.close()
                    throw error
                }
            }
            try output.synchronize()
            try output.close()
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }

        _ = try repairWAV(at: outputURL)
        return BackgroundRecordingResult(
            windowId: manifest.windowId,
            fileURL: outputURL,
            duration: duration
        )
    }

    static func makeRecoveryPreview(from manifest: VoiceRecordingManifest) throws -> URL {
        let result = try makeFinalRecording(from: manifest)
        let previewURL = try recordingDirectory().appendingPathComponent(previewFileName)
        if result.fileURL.path == previewURL.path { return previewURL }
        try? FileManager.default.removeItem(at: previewURL)
        try FileManager.default.copyItem(at: result.fileURL, to: previewURL)
        if result.fileURL.lastPathComponent.hasPrefix("final-") {
            try? FileManager.default.removeItem(at: result.fileURL)
        }
        return previewURL
    }

    static func commitFinalization(_ manifest: VoiceRecordingManifest, keeping finalURL: URL) {
        let urls = (try? segmentURLs(for: manifest)) ?? []
        for url in urls where url.path != finalURL.path {
            try? FileManager.default.removeItem(at: url)
        }
        if let directory = try? recordingDirectory() {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(previewFileName))
        }
        if let url = try? manifestURL() {
            try? FileManager.default.removeItem(at: url)
        }
        if let url = try? identityURL() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func discard(_ manifest: VoiceRecordingManifest) {
        if let urls = try? segmentURLs(for: manifest) {
            for url in urls { try? FileManager.default.removeItem(at: url) }
        }
        if let directory = try? recordingDirectory() {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(previewFileName))
        }
        if let url = try? manifestURL() { try? FileManager.default.removeItem(at: url) }
        if let url = try? identityURL() { try? FileManager.default.removeItem(at: url) }
    }

    static func removeSegment(named name: String, from manifest: inout VoiceRecordingManifest) {
        if let directory = try? recordingDirectory() {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        manifest.segmentFileNames.removeAll { $0 == name }
    }

    private static func manifestURL() throws -> URL {
        try recordingDirectory().appendingPathComponent(manifestFileName)
    }

    private static func identityURL() throws -> URL {
        try recordingDirectory().appendingPathComponent(identityFileName)
    }

    private static func synthesizeManifestFromOrphanedSegments() throws -> VoiceRecordingManifest? {
        let identityData = try? Data(contentsOf: try identityURL())
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let identityData,
              let identity = try? decoder.decode(RecordingIdentity.self, from: identityData) else {
            return nil
        }
        let directory = try recordingDirectory()
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        let names = urls
            .filter { $0.lastPathComponent.hasPrefix("segment-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map(\.lastPathComponent)
        guard !names.isEmpty else { return nil }
        return VoiceRecordingManifest(
            id: identity.id,
            windowId: identity.windowId,
            createdAt: identity.createdAt,
            updatedAt: Date(),
            segmentFileNames: names,
            lastKnownDuration: 0,
            phase: .interrupted
        )
    }

    private static func canonicalHeader(dataByteCount: UInt32) -> Data {
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        var data = Data()
        data.append("RIFF".data(using: .ascii)!)
        data.append(littleEndianData(36 + dataByteCount))
        data.append("WAVEfmt ".data(using: .ascii)!)
        data.append(littleEndianData(UInt32(16)))
        data.append(littleEndianData(UInt16(1)))
        data.append(littleEndianData(channels))
        data.append(littleEndianData(sampleRate))
        data.append(littleEndianData(byteRate))
        data.append(littleEndianData(blockAlign))
        data.append(littleEndianData(bitsPerSample))
        data.append("data".data(using: .ascii)!)
        data.append(littleEndianData(dataByteCount))
        return data
    }

    private static func ascii(_ data: Data, at offset: Int, count: Int) -> String {
        guard offset >= 0, offset + count <= data.count else { return "" }
        return String(data: data.subdata(in: offset..<(offset + count)), encoding: .ascii) ?? ""
    }

    private static func littleEndianUInt16(_ data: Data, at offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func littleEndianData<T: FixedWidthInteger>(_ value: T) -> Data {
        var littleEndian = value.littleEndian
        return withUnsafeBytes(of: &littleEndian) { Data($0) }
    }
}

enum VoiceCaptureContinuityPolicy {
    static func displaysLiveCapture(
        phase: BackgroundRecordingState.Phase,
        belongsToSession: Bool
    ) -> Bool {
        guard belongsToSession else { return false }
        return phase == .starting || phase == .recording
    }

    static func shouldResumeCapture(
        continuationRequested: Bool,
        phase: BackgroundRecordingState.Phase,
        isBackgrounded: Bool,
        recorderIsLive: Bool
    ) -> Bool {
        guard continuationRequested, !isBackgrounded else { return false }
        switch phase {
        case .recording:
            return !recorderIsLive
        case .interrupted, .recovered:
            return true
        case .idle, .starting, .finalizing:
            return false
        }
    }
}

@MainActor
final class BackgroundRecordingState: ObservableObject {
    enum Phase: String, Sendable {
        case idle
        case starting
        case recording
        case interrupted
        case finalizing
        case recovered
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var activeWindowId: String?
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var recoverableRecording: RecoverableVoiceRecording?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isPlayingRecovery = false
    @Published private(set) var isRecoveryScanComplete = false

    let audioRecorder = AudioRecordingService()

    private var manifest: VoiceRecordingManifest?
    private var tickerTask: Task<Void, Never>?
    private var interruptionTask: Task<Void, Never>?
    private var continuityResumeTask: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()
    private var previewPlayer: AVAudioPlayer?
    private var appIsBackgrounded = false
    private var wasCapturingBeforeInterruption = false
    private var captureContinuationRequested = false
    private var lastPersistedWholeSecond = -1
    private var segmentBaseDuration: TimeInterval = 0

    init() {
        observeAudioSystem()
        audioRecorder.onUnexpectedFinish = { [weak self] success in
            guard let self, self.phase == .recording else { return }
            self.handleUnexpectedRecorderFinish(success: success)
        }
        audioRecorder.onFatalRecordingError = { [weak self] message in
            self?.handleFatalRecordingError(message)
        }
        Task { [weak self] in
            await self?.scanForRecovery()
        }
    }

    deinit {
        tickerTask?.cancel()
        interruptionTask?.cancel()
        continuityResumeTask?.cancel()
    }

    var isRecording: Bool {
        phase == .starting || phase == .recording
    }

    var hasInFlightRecording: Bool {
        !isRecoveryScanComplete || (manifest != nil && phase != .idle && phase != .finalizing)
    }

    var startPlan: VoiceCapturePerformancePolicy.StartPlan {
        audioRecorder.startPlan
    }

    var permission: VoiceCapturePerformancePolicy.Permission {
        audioRecorder.permission
    }

    func belongs(to windowId: String) -> Bool {
        activeWindowId == windowId && hasInFlightRecording
    }

    func prepareForRecordingIfAuthorized() async -> Bool {
        guard isRecoveryScanComplete, manifest == nil else { return false }
        return await audioRecorder.prepareForRecordingIfAuthorized()
    }

    func requestPermissionIfNeeded() async -> Bool {
        await audioRecorder.requestPermissionIfNeeded()
    }

    func startRecording(
        windowId: String,
        interactionStartedAt: TimeInterval? = nil,
        continuingRecoveredAudio: Bool = false
    ) async -> Bool {
        guard isRecoveryScanComplete else {
            errorMessage = "Estoy comprobando si quedó un audio anterior. Esperá un instante."
            return false
        }
        if phase == .recording, activeWindowId == windowId { return true }
        guard phase != .starting && phase != .finalizing else { return false }

        if let existing = manifest {
            guard continuingRecoveredAudio,
                  existing.windowId == windowId,
                  phase == .recovered || phase == .interrupted else {
                errorMessage = "Ya hay una grabación activa en otra conversación."
                return false
            }
        } else {
            manifest = VoiceRecordingManifest(
                id: UUID().uuidString,
                windowId: windowId,
                createdAt: Date(),
                updatedAt: Date(),
                segmentFileNames: [],
                lastKnownDuration: 0,
                phase: .starting
            )
        }

        activeWindowId = windowId
        segmentBaseDuration = duration
        phase = .starting
        errorMessage = nil
        recoverableRecording = nil
        stopRecoveryPlayback()
        var registeredSegmentName: String?

        let started = await audioRecorder.startRecording(
            interactionStartedAt: interactionStartedAt,
            recordingWillStart: { [weak self] url in
                guard let self, var pending = self.manifest else {
                    throw VoiceRecordingPersistenceError.recordingDirectoryUnavailable
                }
                try VoiceRecordingPersistence.protectOpenSegment(at: url)
                registeredSegmentName = url.lastPathComponent
                if !pending.segmentFileNames.contains(url.lastPathComponent) {
                    pending.segmentFileNames.append(url.lastPathComponent)
                }
                pending.phase = .starting
                pending.updatedAt = Date()
                try VoiceRecordingPersistence.save(pending)
                self.manifest = pending
            }
        )

        guard started else {
            if var pending = manifest, let registeredSegmentName {
                VoiceRecordingPersistence.removeSegment(named: registeredSegmentName, from: &pending)
                if pending.segmentFileNames.isEmpty {
                    VoiceRecordingPersistence.discard(pending)
                    manifest = nil
                } else {
                    manifest = pending
                }
            }
            if let pending = manifest, !pending.segmentFileNames.isEmpty {
                pendingRecovery(from: pending)
            } else {
                if let empty = manifest { VoiceRecordingPersistence.discard(empty) }
                manifest = nil
                activeWindowId = nil
                duration = 0
                phase = .idle
            }
            errorMessage = audioRecorder.lastError?.localizedDescription ?? "No pude iniciar la grabación."
            return false
        }

        guard var pending = manifest else {
            audioRecorder.cancelRecording(prepareNext: false)
            phase = .idle
            activeWindowId = nil
            errorMessage = "No pude asegurar el archivo de grabación."
            return false
        }
        pending.phase = .recording
        pending.updatedAt = Date()
        try? VoiceRecordingPersistence.save(pending)
        manifest = pending
        phase = .recording
        captureContinuationRequested = true
        lastPersistedWholeSecond = -1
        startTicker()
        return true
    }

    func continueRecoveredRecording(interactionStartedAt: TimeInterval? = nil) async -> Bool {
        guard let windowId = manifest?.windowId else { return false }
        return await startRecording(
            windowId: windowId,
            interactionStartedAt: interactionStartedAt,
            continuingRecoveredAudio: true
        )
    }

    func stopRecording(prepareNext: Bool = true) async -> BackgroundRecordingResult? {
        guard let pending = manifest else {
            errorMessage = AudioRecordingService.RecordingError.noRecordingAvailable.localizedDescription
            return nil
        }
        captureContinuationRequested = false
        continuityResumeTask?.cancel()
        continuityResumeTask = nil
        phase = .finalizing
        stopTicker()
        let backgroundTask = beginFiniteBackgroundTask(named: "Seal voice recording")

        if audioRecorder.hasActiveRecorder {
            _ = await audioRecorder.stopRecording(prepareNext: prepareNext)
        }

        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try VoiceRecordingPersistence.makeFinalRecording(from: pending)
            }.value
            VoiceRecordingPersistence.commitFinalization(pending, keeping: result.fileURL)
            resetToIdle(keepingError: false)
            endFiniteBackgroundTask(backgroundTask)
            return result
        } catch {
            endFiniteBackgroundTask(backgroundTask)
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            pendingRecovery(from: pending)
            return nil
        }
    }

    func finalizeRecoveredRecording() async -> BackgroundRecordingResult? {
        guard phase == .recovered || phase == .interrupted else { return nil }
        return await stopRecording(prepareNext: false)
    }

    func cancelRecording() {
        captureContinuationRequested = false
        continuityResumeTask?.cancel()
        continuityResumeTask = nil
        stopTicker()
        interruptionTask?.cancel()
        interruptionTask = nil
        phase = .finalizing
        audioRecorder.cancelPendingStart()
        audioRecorder.cancelRecording(prepareNext: false)
        if let manifest { VoiceRecordingPersistence.discard(manifest) }
        resetToIdle(keepingError: false)
    }

    func handleScenePhase(isBackground: Bool) {
        appIsBackgrounded = isBackground
        if var pending = manifest {
            pending.lastKnownDuration = duration
            pending.updatedAt = Date()
            try? VoiceRecordingPersistence.save(pending)
            manifest = pending
        } else if appIsBackgrounded {
            audioRecorder.invalidatePreparation(reason: "app en background sin captura")
        }
        if !isBackground {
            ensureCaptureContinuity()
        }
    }

    /// View and connection changes must never own microphone lifetime. This
    /// method is cheap when capture is healthy and repairs a stopped recorder
    /// by sealing the current segment and opening a continuation segment.
    func ensureCaptureContinuity() {
        guard VoiceCaptureContinuityPolicy.shouldResumeCapture(
            continuationRequested: captureContinuationRequested,
            phase: phase,
            isBackgrounded: appIsBackgrounded,
            recorderIsLive: audioRecorder.isRecording
        ) else { return }

        if phase == .recording {
            wasCapturingBeforeInterruption = true
            sealCurrentSegmentForInterruption(
                reason: "la captura perdió continuidad",
                resumesWhenSealed: true
            )
            return
        }
        scheduleCaptureContinuation()
    }

    func toggleRecoveryPlayback() async {
        if isPlayingRecovery {
            stopRecoveryPlayback()
            return
        }
        guard let manifest else { return }
        do {
            let url = try await Task.detached(priority: .userInitiated) {
                try VoiceRecordingPersistence.makeRecoveryPreview(from: manifest)
            }.value
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            previewPlayer = player
            isPlayingRecovery = player.play()
            if isPlayingRecovery {
                Task { [weak self, weak player] in
                    while player?.isPlaying == true {
                        try? await Task.sleep(for: .milliseconds(150))
                    }
                    guard !Task.isCancelled else { return }
                    self?.isPlayingRecovery = false
                }
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            isPlayingRecovery = false
        }
    }

    func stopRecoveryPlayback() {
        previewPlayer?.stop()
        previewPlayer = nil
        isPlayingRecovery = false
    }

    func dismissError() {
        errorMessage = nil
    }

    private func scanForRecovery() async {
        let result = await Task.detached(priority: .utility) {
            Result { try VoiceRecordingPersistence.recoverManifest() }
        }.value
        isRecoveryScanComplete = true
        guard phase == .idle else { return }
        let recovered: (
            manifest: VoiceRecordingManifest,
            duration: TimeInterval,
            hasPlayableAudio: Bool
        )?
        switch result {
        case let .success(value):
            recovered = value
        case let .failure(error):
            errorMessage = "Encontré datos de una grabación anterior, pero no pude leer su registro. No borré ningún archivo. \(error.localizedDescription)"
            return
        }
        guard let recovered else { return }
        let manifest = recovered.manifest
        let recoveredDuration = recovered.duration
        self.manifest = manifest
        activeWindowId = manifest.windowId
        duration = recoveredDuration
        level = 0
        phase = .recovered
        recoverableRecording = RecoverableVoiceRecording(
            id: manifest.id,
            windowId: manifest.windowId,
            createdAt: manifest.createdAt,
            duration: recoveredDuration,
            segmentCount: manifest.segmentFileNames.count,
            hasPlayableAudio: recovered.hasPlayableAudio
        )
        if !recovered.hasPlayableAudio {
            errorMessage = "Conservé el registro y sus archivos, pero todavía no pude abrir el audio. No voy a borrarlo automáticamente."
        }
    }

    private func pendingRecovery(from pending: VoiceRecordingManifest) {
        var recovered = pending
        recovered.phase = .interrupted
        recovered.lastKnownDuration = max(recovered.lastKnownDuration, duration)
        recovered.updatedAt = Date()
        try? VoiceRecordingPersistence.save(recovered)
        manifest = recovered
        activeWindowId = recovered.windowId
        phase = .recovered
        level = 0
        recoverableRecording = RecoverableVoiceRecording(
            id: recovered.id,
            windowId: recovered.windowId,
            createdAt: recovered.createdAt,
            duration: duration,
            segmentCount: recovered.segmentFileNames.count,
            hasPlayableAudio: VoiceRecordingPersistence.hasPlayableAudio(in: recovered)
        )
    }

    private func startTicker() {
        stopTicker()
        tickerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.phase == .recording else { return }
                guard self.audioRecorder.isRecording else {
                    self.ensureCaptureContinuity()
                    return
                }
                self.duration = self.segmentBaseDuration + self.audioRecorder.currentTime
                self.level = self.appIsBackgrounded ? 0 : self.audioRecorder.currentLevel
                let wholeSecond = Int(self.duration.rounded(.down))
                if wholeSecond != self.lastPersistedWholeSecond {
                    self.lastPersistedWholeSecond = wholeSecond
                    self.persistProgress()
                }
                let milliseconds = self.appIsBackgrounded ? 500 : 80
                try? await Task.sleep(for: .milliseconds(milliseconds))
            }
        }
    }

    private func stopTicker() {
        tickerTask?.cancel()
        tickerTask = nil
        level = 0
    }

    private func persistProgress() {
        guard var pending = manifest else { return }
        pending.lastKnownDuration = duration
        pending.updatedAt = Date()
        pending.phase = phase == .recording ? .recording : .interrupted
        try? VoiceRecordingPersistence.save(pending)
        manifest = pending
    }

    private func observeAudioSystem() {
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .sink { [weak self] notification in
                Task { @MainActor in self?.handleInterruption(notification) }
            }
            .store(in: &subscriptions)

        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .sink { [weak self] notification in
                Task { @MainActor in self?.handleRouteChange(notification) }
            }
            .store(in: &subscriptions)

        NotificationCenter.default.publisher(for: AVAudioSession.mediaServicesWereResetNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.handleMediaServicesReset() }
            }
            .store(in: &subscriptions)
    }

    private func handleInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        switch type {
        case .began:
            guard phase == .recording || phase == .starting else {
                audioRecorder.invalidatePreparation(reason: "interrupción del sistema")
                return
            }
            wasCapturingBeforeInterruption = true
            sealCurrentSegmentForInterruption(reason: "interrupción del sistema")
        case .ended:
            guard wasCapturingBeforeInterruption, phase == .interrupted else { return }
            wasCapturingBeforeInterruption = false
            // `shouldResume` is advisory and is absent for some short system
            // interruptions. The user's still-active recording intent is the
            // source of truth, so retry whenever the app is active.
            if appIsBackgrounded, let pending = manifest {
                pendingRecovery(from: pending)
            } else {
                scheduleCaptureContinuation()
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason),
              reason != .categoryChange,
              reason != .override else { return }
        audioRecorder.invalidatePreparation(reason: "ruta de audio \(reason.rawValue)")
        if phase == .recording, !audioRecorder.isRecording {
            wasCapturingBeforeInterruption = true
            sealCurrentSegmentForInterruption(
                reason: "cambio de ruta",
                resumesWhenSealed: true
            )
        }
    }

    private func handleMediaServicesReset() {
        guard manifest != nil else {
            audioRecorder.invalidatePreparation(reason: "media services reset")
            return
        }
        stopTicker()
        _ = audioRecorder.abandonActiveRecordingAfterMediaServicesReset()
        if let pending = manifest {
            errorMessage = "El sistema de audio se reinició. Conservé lo grabado para que puedas continuarlo."
            pendingRecovery(from: pending)
            scheduleCaptureContinuation(after: .milliseconds(250))
        }
    }

    private func handleUnexpectedRecorderFinish(success: Bool) {
        guard manifest != nil else { return }
        wasCapturingBeforeInterruption = false
        sealCurrentSegmentForInterruption(
            reason: success ? "el grabador finalizó inesperadamente" : "el grabador informó un error",
            resumesWhenSealed: true
        )
    }

    private func handleFatalRecordingError(_ message: String) {
        errorMessage = "El sistema informó un error de audio. Conservé lo grabado. \(message)"
        if phase == .recording {
            sealCurrentSegmentForInterruption(
                reason: "error de codificación",
                resumesWhenSealed: true
            )
        }
    }

    private func sealCurrentSegmentForInterruption(
        reason: String,
        resumesWhenSealed: Bool = false
    ) {
        guard phase == .recording || phase == .starting else { return }
        phase = .interrupted
        stopTicker()
        audioRecorder.invalidatePreparation(reason: reason)
        interruptionTask?.cancel()
        interruptionTask = Task { @MainActor [weak self] in
            guard let self, let pending = self.manifest else { return }
            let backgroundTask = self.beginFiniteBackgroundTask(named: "Preserve interrupted voice recording")
            if self.audioRecorder.hasActiveRecorder {
                _ = await self.audioRecorder.stopRecording(prepareNext: false)
            }
            self.duration = max(self.duration, pending.lastKnownDuration)
            var updated = pending
            updated.phase = .interrupted
            updated.lastKnownDuration = self.duration
            updated.updatedAt = Date()
            try? VoiceRecordingPersistence.save(updated)
            self.manifest = updated
            self.endFiniteBackgroundTask(backgroundTask)
            if resumesWhenSealed {
                self.scheduleCaptureContinuation(after: .milliseconds(120))
            }
        }
    }

    private func scheduleCaptureContinuation(after delay: Duration = .zero) {
        guard captureContinuationRequested, !appIsBackgrounded else { return }
        let sealingTask = interruptionTask
        continuityResumeTask?.cancel()
        continuityResumeTask = Task { @MainActor [weak self] in
            if let sealingTask {
                await sealingTask.value
            }
            if delay != .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled, let self,
                  self.captureContinuationRequested,
                  !self.appIsBackgrounded,
                  let windowId = self.activeWindowId,
                  self.phase == .interrupted || self.phase == .recovered else {
                return
            }
            let resumed = await self.startRecording(
                windowId: windowId,
                continuingRecoveredAudio: true
            )
            if !resumed, let pending = self.manifest {
                self.pendingRecovery(from: pending)
            }
            self.continuityResumeTask = nil
        }
    }

    private func beginFiniteBackgroundTask(named name: String) -> UIBackgroundTaskIdentifier {
        var identifier: UIBackgroundTaskIdentifier = .invalid
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            if identifier != .invalid {
                UIApplication.shared.endBackgroundTask(identifier)
                identifier = .invalid
            }
        }
        return identifier
    }

    private func endFiniteBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
    }

    private func resetToIdle(keepingError: Bool) {
        stopTicker()
        interruptionTask?.cancel()
        interruptionTask = nil
        continuityResumeTask?.cancel()
        continuityResumeTask = nil
        stopRecoveryPlayback()
        manifest = nil
        activeWindowId = nil
        duration = 0
        level = 0
        recoverableRecording = nil
        phase = .idle
        wasCapturingBeforeInterruption = false
        captureContinuationRequested = false
        lastPersistedWholeSecond = -1
        segmentBaseDuration = 0
        if !keepingError { errorMessage = nil }
    }
}
