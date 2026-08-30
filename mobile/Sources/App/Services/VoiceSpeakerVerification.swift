import Foundation
import Eagle

protocol VoiceSpeakerVerifying: Sendable {
    func verify(
        waveFileURL: URL,
        segments: [VoiceTranscriptionSegment]
    ) async throws -> [String: VoiceSegmentVerification]
}

enum VoiceEnrollmentPolicy {
    static let minimumDuration: TimeInterval = 8
    static let preferredDuration: TimeInterval = 15
    static let knownSpeakerReferenceDuration: TimeInterval = 10
    static let segmentPadding: TimeInterval = 0.12
}

struct VoiceEnrollmentResult: Equatable, Sendable {
    let profileByteCount: Int
    let processedDuration: TimeInterval
}

enum VoiceSpeakerVerificationError: LocalizedError, Equatable {
    case accessKeyUnavailable
    case profileUnavailable
    case invalidAudio
    case enrollmentTooShort(required: TimeInterval, actual: TimeInterval)
    case enrollmentIncomplete(Float)
    case profileStorageFailed
    case referenceStorageFailed

    var errorDescription: String? {
        switch self {
        case .accessKeyUnavailable:
            return "Falta configurar PICOVOICE_ACCESS_KEY para crear y usar tu perfil local."
        case .profileUnavailable:
            return "Todavía no hay un perfil de voz enrolado."
        case .invalidAudio:
            return "La muestra debe ser WAV mono PCM de 16 kHz."
        case .enrollmentTooShort(let required, let actual):
            return "La muestra es demasiado corta (\(Int(actual)) s). Grabá al menos \(Int(required)) segundos."
        case .enrollmentIncomplete(let progress):
            return "No hubo suficiente voz clara para completar el perfil (\(Int(progress))%)."
        case .profileStorageFailed:
            return "No pude guardar el perfil de voz de forma segura."
        case .referenceStorageFailed:
            return "No pude guardar la referencia vocal protegida."
        }
    }
}

struct VoiceKnownSpeakerReferenceStore: Sendable {
    private static let fileName = "known-speaker-reference.wav"
    private let directoryOverride: URL?

    init(directory: URL? = nil) {
        directoryOverride = directory
    }

    func save(from wave: PCM16WavePayload) throws -> URL {
        guard wave.sampleRate == 16_000, wave.channels == 1 else {
            throw VoiceSpeakerVerificationError.invalidAudio
        }
        let maximumByteCount = Int(
            Double(wave.sampleRate * MemoryLayout<Int16>.size)
                * VoiceEnrollmentPolicy.knownSpeakerReferenceDuration
        )
        let referenceBytes = Data(wave.bytes.prefix(maximumByteCount))
        guard !referenceBytes.isEmpty else {
            throw VoiceSpeakerVerificationError.invalidAudio
        }
        let outputURL = try referenceURL()
        let waveData = try Self.makeWaveData(
            pcmBytes: referenceBytes,
            sampleRate: wave.sampleRate,
            channels: wave.channels
        )
        try waveData.write(to: outputURL, options: [.atomic, .completeFileProtection])
        return outputURL
    }

    func availableReferenceURL() -> URL? {
        guard let url = try? referenceURL(),
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    func deleteReference() {
        guard let url = try? referenceURL() else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func referenceURL() throws -> URL {
        let directory: URL
        if let directoryOverride {
            directory = directoryOverride
        } else {
            guard let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                throw VoiceSpeakerVerificationError.referenceStorageFailed
            }
            directory = applicationSupport
                .appendingPathComponent("KyCode", isDirectory: true)
                .appendingPathComponent("VoiceIdentity", isDirectory: true)
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        return directory.appendingPathComponent(Self.fileName)
    }

    private static func makeWaveData(
        pcmBytes: Data,
        sampleRate: Int,
        channels: Int
    ) throws -> Data {
        guard pcmBytes.count <= Int(UInt32.max),
              sampleRate > 0,
              channels > 0 else {
            throw VoiceSpeakerVerificationError.referenceStorageFailed
        }
        let bitsPerSample: UInt16 = 16
        let channelCount = UInt16(channels)
        let rate = UInt32(sampleRate)
        let dataByteCount = UInt32(pcmBytes.count)
        var data = Data()
        data.append(Data("RIFF".utf8))
        data.append(littleEndianData(36 + dataByteCount))
        data.append(Data("WAVEfmt ".utf8))
        data.append(littleEndianData(UInt32(16)))
        data.append(littleEndianData(UInt16(1)))
        data.append(littleEndianData(channelCount))
        data.append(littleEndianData(rate))
        data.append(littleEndianData(rate * UInt32(channelCount) * UInt32(bitsPerSample / 8)))
        data.append(littleEndianData(channelCount * (bitsPerSample / 8)))
        data.append(littleEndianData(bitsPerSample))
        data.append(Data("data".utf8))
        data.append(littleEndianData(dataByteCount))
        data.append(pcmBytes)
        return data
    }

    private static func littleEndianData<T: FixedWidthInteger>(_ value: T) -> Data {
        var littleEndian = value.littleEndian
        return withUnsafeBytes(of: &littleEndian) { Data($0) }
    }
}

enum VoiceIsolationSecrets {
    static func loadPicovoiceAccessKey() -> String? {
        loadOptionalString("PICOVOICE_ACCESS_KEY")
    }

    private static func loadOptionalString(_ key: String) -> String? {
        for url in candidateSecretURLs() {
            guard let dictionary = NSDictionary(contentsOf: url) as? [String: Any],
                  let raw = dictionary[key] as? String else {
                continue
            }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty, !value.hasPrefix("YOUR_") {
                return value
            }
        }
        let environmentValue = ProcessInfo.processInfo.environment[key]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let environmentValue, !environmentValue.isEmpty {
            return environmentValue
        }
        return nil
    }

    private static func candidateSecretURLs() -> [URL] {
        var urls: [URL] = []
        if let bundleURL = Bundle.main.url(forResource: "Secrets", withExtension: "plist") {
            urls.append(bundleURL)
        }
        let containingAppURL = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Secrets.plist")
        urls.append(containingAppURL)
        if let appGroupURL = SharedInbox.containerURL()?.appendingPathComponent("Secrets.plist") {
            urls.append(appGroupURL)
        }
        return urls
    }
}

protocol VoiceSpeakerProfileStoring: Sendable {
    func loadProfile() -> Data?
    func saveProfile(_ profile: Data) -> Bool
    func deleteProfile()
}

struct KeychainVoiceSpeakerProfileStore: VoiceSpeakerProfileStoring {
    func loadProfile() -> Data? {
        KycodeKeychain.loadVoiceProfile()
    }

    func saveProfile(_ profile: Data) -> Bool {
        KycodeKeychain.saveVoiceProfile(profile)
    }

    func deleteProfile() {
        KycodeKeychain.deleteVoiceProfile()
    }
}

actor EagleSpeakerVerificationService: VoiceSpeakerVerifying {
    private let accessKey: String?
    private let referenceStore: VoiceKnownSpeakerReferenceStore
    private let profileStore: any VoiceSpeakerProfileStoring

    init(
        accessKey: String? = VoiceIsolationSecrets.loadPicovoiceAccessKey(),
        referenceStore: VoiceKnownSpeakerReferenceStore = VoiceKnownSpeakerReferenceStore(),
        profileStore: any VoiceSpeakerProfileStoring = KeychainVoiceSpeakerProfileStore()
    ) {
        self.accessKey = accessKey
        self.referenceStore = referenceStore
        self.profileStore = profileStore
    }

    nonisolated var isConfigured: Bool {
        accessKey?.isEmpty == false
    }

    nonisolated var hasEnrolledProfile: Bool {
        profileStore.loadProfile()?.isEmpty == false
    }

    func enroll(
        waveFileURL: URL,
        onProgress: @Sendable (Float) async -> Void = { _ in }
    ) async throws -> VoiceEnrollmentResult {
        guard let accessKey, !accessKey.isEmpty else {
            throw VoiceSpeakerVerificationError.accessKeyUnavailable
        }
        let wave = try loadWave(at: waveFileURL)
        let samples = VoicePCMUtilities.int16Samples(from: wave)
        let duration = Double(samples.count) / Double(wave.sampleRate)
        guard duration >= VoiceEnrollmentPolicy.minimumDuration else {
            throw VoiceSpeakerVerificationError.enrollmentTooShort(
                required: VoiceEnrollmentPolicy.minimumDuration,
                actual: duration
            )
        }

        let profiler = try EagleProfiler(
            accessKey: accessKey,
            minEnrollmentChunks: 8,
            voiceThreshold: 0.3
        )
        defer { profiler.delete() }

        let frameLength = EagleProfiler.frameLength
        var offset = 0
        var progress: Float = 0
        while offset + frameLength <= samples.count, progress < 100 {
            progress = try profiler.enroll(pcm: Array(samples[offset..<(offset + frameLength)]))
            offset += frameLength
            await onProgress(min(1, max(0, progress / 100)))
        }
        if progress < 100 {
            progress = try profiler.flush()
            await onProgress(min(1, max(0, progress / 100)))
        }
        guard progress >= 100 else {
            throw VoiceSpeakerVerificationError.enrollmentIncomplete(progress)
        }

        let profileData = Data(try profiler.export().getBytes())
        do {
            _ = try referenceStore.save(from: wave)
        } catch {
            throw VoiceSpeakerVerificationError.referenceStorageFailed
        }
        guard profileStore.saveProfile(profileData) else {
            referenceStore.deleteReference()
            throw VoiceSpeakerVerificationError.profileStorageFailed
        }
        return VoiceEnrollmentResult(
            profileByteCount: profileData.count,
            processedDuration: Double(offset) / Double(wave.sampleRate)
        )
    }

    func deleteProfile() {
        profileStore.deleteProfile()
        referenceStore.deleteReference()
    }

    func verify(
        waveFileURL: URL,
        segments: [VoiceTranscriptionSegment]
    ) async throws -> [String: VoiceSegmentVerification] {
        guard let accessKey, !accessKey.isEmpty else {
            throw VoiceSpeakerVerificationError.accessKeyUnavailable
        }
        guard let storedProfile = profileStore.loadProfile(), !storedProfile.isEmpty else {
            throw VoiceSpeakerVerificationError.profileUnavailable
        }
        let wave = try loadWave(at: waveFileURL)
        let samples = VoicePCMUtilities.int16Samples(from: wave)
        let profile = EagleProfile(profileBytes: [UInt8](storedProfile))
        let engine = try Eagle(accessKey: accessKey, voiceThreshold: 0.3)
        defer { engine.delete() }
        let frameLength = try engine.minProcessSamples()

        var verifications: [String: VoiceSegmentVerification] = [:]
        for segment in segments {
            let segmentSamples = VoicePCMUtilities.slice(
                samples: samples,
                sampleRate: wave.sampleRate,
                start: segment.start,
                end: segment.end,
                padding: VoiceEnrollmentPolicy.segmentPadding
            )
            var scores: [Float] = []
            var offset = 0
            while offset + frameLength <= segmentSamples.count {
                let frame = Array(segmentSamples[offset..<(offset + frameLength)])
                if let frameScores = try engine.process(pcm: frame, speakerProfiles: [profile]),
                   let score = frameScores.first,
                   score.isFinite {
                    scores.append(score)
                }
                offset += frameLength
            }
            verifications[segment.id] = VoiceSegmentVerification(
                segmentId: segment.id,
                scores: scores,
                validFrameCount: scores.count
            )
        }
        return verifications
    }

    private func loadWave(at url: URL) throws -> PCM16WavePayload {
        do {
            let wave = try PCM16WavePayload.read(from: Data(contentsOf: url))
            guard wave.sampleRate == Eagle.sampleRate, wave.channels == 1 else {
                throw VoiceSpeakerVerificationError.invalidAudio
            }
            return wave
        } catch let error as VoiceSpeakerVerificationError {
            throw error
        } catch {
            throw VoiceSpeakerVerificationError.invalidAudio
        }
    }
}
