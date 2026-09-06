import Foundation

enum VoiceIsolationMode: String, Codable, CaseIterable, Sendable {
    case off
    case appleProcessing
    case personalized

    var usesAppleVoiceProcessing: Bool {
        self != .off
    }

    var usesSpeakerVerification: Bool {
        self == .personalized
    }

    var title: String {
        switch self {
        case .off: return "Desactivado"
        case .appleProcessing: return "Voz clara"
        case .personalized: return "Solo mi voz"
        }
    }

    var explanation: String {
        switch self {
        case .off:
            return "Graba y transcribe sin aislamiento."
        case .appleProcessing:
            return "Reduce eco y ruido con el procesamiento de Apple."
        case .personalized:
            return "Además compara cada turno con tu perfil local."
        }
    }
}

enum VoiceIsolationPreferences {
    static let modeDefaultsKey = "kycode.mobile.voiceIsolation.mode.v1"
    static let thresholdDefaultsKey = "kycode.mobile.voiceIsolation.threshold.v1"
    static let defaultMode: VoiceIsolationMode = .personalized
    static let defaultThreshold: Float = 0.55

    static func loadMode(from defaults: UserDefaults = .standard) -> VoiceIsolationMode {
        guard let raw = defaults.string(forKey: modeDefaultsKey),
              let mode = VoiceIsolationMode(rawValue: raw) else {
            return defaultMode
        }
        return mode
    }

    static func saveMode(_ mode: VoiceIsolationMode, to defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: modeDefaultsKey)
    }

    static func loadThreshold(from defaults: UserDefaults = .standard) -> Float {
        guard defaults.object(forKey: thresholdDefaultsKey) != nil else {
            return defaultThreshold
        }
        return clampedThreshold(defaults.float(forKey: thresholdDefaultsKey))
    }

    static func saveThreshold(_ threshold: Float, to defaults: UserDefaults = .standard) {
        defaults.set(clampedThreshold(threshold), forKey: thresholdDefaultsKey)
    }

    static func clampedThreshold(_ threshold: Float) -> Float {
        min(0.95, max(0.05, threshold.isFinite ? threshold : defaultThreshold))
    }
}


struct VoiceTranscriptionSegment: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let speakerId: String?
    let start: TimeInterval
    let end: TimeInterval
    let text: String

    init(
        id: String = UUID().uuidString,
        speakerId: String?,
        start: TimeInterval,
        end: TimeInterval,
        text: String
    ) {
        self.id = id
        self.speakerId = speakerId
        self.start = start
        self.end = end
        self.text = text
    }

    var duration: TimeInterval {
        max(0, end - start)
    }

    var normalizedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum VoiceTranscriptionProvider: String, Codable, Sendable {
    case mistralVoxtral
    case openAIKnownSpeakerBenchmark
}

struct VoiceTranscriptionResult: Codable, Equatable, Sendable {
    let fullText: String
    let segments: [VoiceTranscriptionSegment]
    let provider: VoiceTranscriptionProvider
    let model: String
    let latencyMilliseconds: Int

    init(
        fullText: String,
        segments: [VoiceTranscriptionSegment] = [],
        provider: VoiceTranscriptionProvider = .mistralVoxtral,
        model: String,
        latencyMilliseconds: Int
    ) {
        self.fullText = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.segments = segments
        self.provider = provider
        self.model = model
        self.latencyMilliseconds = latencyMilliseconds
    }
}

struct VoiceSegmentVerification: Codable, Equatable, Sendable {
    let segmentId: String
    let scores: [Float]
    let validFrameCount: Int

    var medianScore: Float? {
        VoiceIsolationPolicy.median(scores)
    }
}

enum VoiceIsolationFallbackReason: String, Codable, Equatable, Sendable {
    case disabled
    case speakerVerificationNotRequested
    case profileUnavailable
    case verifierUnavailable
    case missingDiarizationSegments
    case insufficientVoiceEvidence
    case noTargetSegments
    case isolatedTextTooShort
    case acceptedDurationTooLow
    case processingFailed

    var userMessage: String {
        switch self {
        case .disabled:
            return "El aislamiento está desactivado."
        case .speakerVerificationNotRequested:
            return "Se aplicó limpieza de voz sin identificación personal."
        case .profileUnavailable:
            return "Todavía no hay un perfil de voz enrolado."
        case .verifierUnavailable:
            return "La identificación local no está disponible."
        case .missingDiarizationSegments:
            return "Voxtral no devolvió turnos de hablantes utilizables."
        case .insufficientVoiceEvidence:
            return "No hubo suficiente voz para identificarla con seguridad."
        case .noTargetSegments:
            return "Ningún turno alcanzó la confianza necesaria."
        case .isolatedTextTooShort:
            return "El resultado aislado quedó demasiado corto para usarlo con seguridad."
        case .acceptedDurationTooLow:
            return "La porción identificada fue demasiado pequeña."
        case .processingFailed:
            return "La identificación local falló; conservé el texto completo."
        }
    }
}

struct VoiceIsolationSegmentDecision: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let speakerId: String?
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    let score: Float?
    let validFrameCount: Int
    let accepted: Bool
}

struct VoiceIsolationReport: Codable, Equatable, Sendable {
    let mode: VoiceIsolationMode
    let fullText: String
    let isolatedText: String?
    let selectedText: String
    let applied: Bool
    let fallbackReason: VoiceIsolationFallbackReason?
    let aggregateConfidence: Float?
    let segments: [VoiceIsolationSegmentDecision]
    let verificationLatencyMilliseconds: Int

    var rejectedSegments: [VoiceIsolationSegmentDecision] {
        segments.filter { !$0.accepted }
    }

    var acceptedSegments: [VoiceIsolationSegmentDecision] {
        segments.filter(\.accepted)
    }
}

enum VoiceIsolationPolicy {
    static let transcriptionTimeout: Duration = .seconds(90)
    static let minimumValidFramesPerSegment = 2
    static let minimumTotalValidFrames = 2
    static let minimumIsolatedWordCount = 3
    static let fullTextWordCountRequiringMinimum = 6
    static let minimumAcceptedDurationRatio: Double = 0.12

    static func decide(
        transcription: VoiceTranscriptionResult,
        mode: VoiceIsolationMode,
        threshold: Float,
        verifications: [String: VoiceSegmentVerification],
        verificationLatencyMilliseconds: Int = 0,
        unavailableReason: VoiceIsolationFallbackReason? = nil
    ) -> VoiceIsolationReport {
        let fullText = transcription.fullText
        guard mode.usesSpeakerVerification else {
            return fallback(
                mode: mode,
                fullText: fullText,
                reason: .disabled,
                segments: [],
                verificationLatencyMilliseconds: verificationLatencyMilliseconds
            )
        }
        if let unavailableReason {
            return fallback(
                mode: mode,
                fullText: fullText,
                reason: unavailableReason,
                segments: [],
                verificationLatencyMilliseconds: verificationLatencyMilliseconds
            )
        }

        let usableSegments = transcription.segments.filter {
            $0.end > $0.start && !$0.normalizedText.isEmpty
        }
        guard !usableSegments.isEmpty else {
            return fallback(
                mode: mode,
                fullText: fullText,
                reason: .missingDiarizationSegments,
                segments: [],
                verificationLatencyMilliseconds: verificationLatencyMilliseconds
            )
        }

        let normalizedThreshold = VoiceIsolationPreferences.clampedThreshold(threshold)
        let decisions = usableSegments.map { segment -> VoiceIsolationSegmentDecision in
            let verification = verifications[segment.id]
            let score = verification?.medianScore
            let frameCount = verification?.validFrameCount ?? 0
            return VoiceIsolationSegmentDecision(
                id: segment.id,
                speakerId: segment.speakerId,
                start: segment.start,
                end: segment.end,
                text: segment.normalizedText,
                score: score,
                validFrameCount: frameCount,
                accepted: frameCount >= minimumValidFramesPerSegment
                    && (score ?? 0) >= normalizedThreshold
            )
        }

        let totalValidFrames = decisions.reduce(0) { $0 + $1.validFrameCount }
        guard totalValidFrames >= minimumTotalValidFrames else {
            return fallback(
                mode: mode,
                fullText: fullText,
                reason: .insufficientVoiceEvidence,
                segments: decisions,
                verificationLatencyMilliseconds: verificationLatencyMilliseconds
            )
        }

        let accepted = decisions.filter(\.accepted)
        guard !accepted.isEmpty else {
            return fallback(
                mode: mode,
                fullText: fullText,
                reason: .noTargetSegments,
                segments: decisions,
                verificationLatencyMilliseconds: verificationLatencyMilliseconds
            )
        }

        let isolatedText = accepted.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if wordCount(isolatedText) < minimumIsolatedWordCount,
           wordCount(fullText) >= fullTextWordCountRequiringMinimum {
            return fallback(
                mode: mode,
                fullText: fullText,
                isolatedText: isolatedText,
                reason: .isolatedTextTooShort,
                segments: decisions,
                verificationLatencyMilliseconds: verificationLatencyMilliseconds
            )
        }

        let totalDuration = decisions.reduce(0.0) { $0 + max(0, $1.end - $1.start) }
        let acceptedDuration = accepted.reduce(0.0) { $0 + max(0, $1.end - $1.start) }
        if totalDuration > 0,
           acceptedDuration / totalDuration < minimumAcceptedDurationRatio {
            return fallback(
                mode: mode,
                fullText: fullText,
                isolatedText: isolatedText,
                reason: .acceptedDurationTooLow,
                segments: decisions,
                verificationLatencyMilliseconds: verificationLatencyMilliseconds
            )
        }

        let aggregateConfidence = median(accepted.compactMap(\.score))
        return VoiceIsolationReport(
            mode: mode,
            fullText: fullText,
            isolatedText: isolatedText,
            selectedText: isolatedText,
            applied: true,
            fallbackReason: nil,
            aggregateConfidence: aggregateConfidence,
            segments: decisions,
            verificationLatencyMilliseconds: verificationLatencyMilliseconds
        )
    }

    static func median(_ scores: [Float]) -> Float? {
        let valid = scores.filter(\.isFinite).sorted()
        guard !valid.isEmpty else { return nil }
        let middle = valid.count / 2
        if valid.count.isMultiple(of: 2) {
            return (valid[middle - 1] + valid[middle]) / 2
        }
        return valid[middle]
    }

    static func fullTranscript(
        transcription: VoiceTranscriptionResult,
        mode: VoiceIsolationMode,
        reason: VoiceIsolationFallbackReason
    ) -> VoiceIsolationReport {
        fallback(
            mode: mode,
            fullText: transcription.fullText,
            reason: reason,
            segments: [],
            verificationLatencyMilliseconds: 0
        )
    }

    private static func fallback(
        mode: VoiceIsolationMode,
        fullText: String,
        isolatedText: String? = nil,
        reason: VoiceIsolationFallbackReason,
        segments: [VoiceIsolationSegmentDecision],
        verificationLatencyMilliseconds: Int
    ) -> VoiceIsolationReport {
        VoiceIsolationReport(
            mode: mode,
            fullText: fullText,
            isolatedText: isolatedText,
            selectedText: fullText,
            applied: false,
            fallbackReason: reason,
            aggregateConfidence: nil,
            segments: segments,
            verificationLatencyMilliseconds: verificationLatencyMilliseconds
        )
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}

enum VoiceIsolationProcessor {
    static func apply(
        transcription: VoiceTranscriptionResult,
        waveFileURL: URL,
        mode: VoiceIsolationMode,
        threshold: Float,
        verifier: any VoiceSpeakerVerifying
    ) async -> VoiceIsolationReport {
        guard mode.usesSpeakerVerification else {
            return VoiceIsolationPolicy.fullTranscript(
                transcription: transcription,
                mode: mode,
                reason: mode == .off ? .disabled : .speakerVerificationNotRequested
            )
        }

        let startedAt = Date()
        do {
            let verifications = try await verifier.verify(
                waveFileURL: waveFileURL,
                segments: transcription.segments
            )
            return VoiceIsolationPolicy.decide(
                transcription: transcription,
                mode: mode,
                threshold: threshold,
                verifications: verifications,
                verificationLatencyMilliseconds: Int(Date().timeIntervalSince(startedAt) * 1_000)
            )
        } catch let error as VoiceSpeakerVerificationError {
            let reason: VoiceIsolationFallbackReason
            switch error {
            case .accessKeyUnavailable:
                reason = .verifierUnavailable
            case .profileUnavailable:
                reason = .profileUnavailable
            default:
                reason = .processingFailed
            }
            return VoiceIsolationPolicy.decide(
                transcription: transcription,
                mode: mode,
                threshold: threshold,
                verifications: [:],
                verificationLatencyMilliseconds: Int(Date().timeIntervalSince(startedAt) * 1_000),
                unavailableReason: reason
            )
        } catch {
            return VoiceIsolationPolicy.decide(
                transcription: transcription,
                mode: mode,
                threshold: threshold,
                verifications: [:],
                verificationLatencyMilliseconds: Int(Date().timeIntervalSince(startedAt) * 1_000),
                unavailableReason: .processingFailed
            )
        }
    }
}

enum VoicePCMUtilities {
    static func int16Samples(from payload: PCM16WavePayload) -> [Int16] {
        let bytes = payload.bytes
        guard bytes.count >= 2 else { return [] }
        var samples: [Int16] = []
        samples.reserveCapacity(bytes.count / 2)
        var offset = 0
        while offset + 1 < bytes.count {
            let raw = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
            samples.append(Int16(bitPattern: raw))
            offset += 2
        }
        return samples
    }

    static func slice(
        samples: [Int16],
        sampleRate: Int,
        start: TimeInterval,
        end: TimeInterval,
        padding: TimeInterval = 0
    ) -> [Int16] {
        guard sampleRate > 0, !samples.isEmpty, end > start else { return [] }
        let duration = TimeInterval(samples.count) / TimeInterval(sampleRate)
        let paddedStart = max(0, min(duration, start - max(0, padding)))
        let paddedEnd = max(paddedStart, min(duration, end + max(0, padding)))
        let lower = min(samples.count, max(0, Int((paddedStart * Double(sampleRate)).rounded(.down))))
        let upper = min(samples.count, max(lower, Int((paddedEnd * Double(sampleRate)).rounded(.up))))
        guard upper > lower else { return [] }
        return Array(samples[lower..<upper])
    }
}

struct VoiceIsolationEvaluation: Codable, Equatable, Sendable {
    let targetWordErrorRate: Double
    let backgroundWordRetentionRate: Double
    let backgroundDiscriminativeWordCount: Int
    let outputWordCount: Int
}

enum VoiceIsolationMetrics {
    static func evaluate(
        targetReference: String,
        backgroundReference: String,
        output: String
    ) -> VoiceIsolationEvaluation {
        let targetWords = words(in: targetReference)
        let backgroundWords = words(in: backgroundReference)
        let outputWords = words(in: output)
        let discriminativeBackgroundWords = subtractingMultiset(
            backgroundWords,
            removing: targetWords
        )
        return VoiceIsolationEvaluation(
            targetWordErrorRate: wordErrorRate(reference: targetWords, hypothesis: outputWords),
            backgroundWordRetentionRate: multisetRetentionRate(
                reference: discriminativeBackgroundWords,
                hypothesis: outputWords
            ),
            backgroundDiscriminativeWordCount: discriminativeBackgroundWords.count,
            outputWordCount: outputWords.count
        )
    }

    static func relativeWERImprovement(baseline: Double, candidate: Double) -> Double {
        guard baseline.isFinite, candidate.isFinite, baseline > 0 else { return 0 }
        return (baseline - candidate) / baseline
    }

    static func words(in text: String) -> [String] {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "es")
        )
        return folded
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func wordErrorRate(reference: [String], hypothesis: [String]) -> Double {
        guard !reference.isEmpty else { return hypothesis.isEmpty ? 0 : 1 }
        var previous = Array(0...hypothesis.count)
        for (referenceIndex, referenceWord) in reference.enumerated() {
            var current = Array(repeating: 0, count: hypothesis.count + 1)
            current[0] = referenceIndex + 1
            for (hypothesisIndex, hypothesisWord) in hypothesis.enumerated() {
                let substitutionCost = referenceWord == hypothesisWord ? 0 : 1
                current[hypothesisIndex + 1] = min(
                    current[hypothesisIndex] + 1,
                    previous[hypothesisIndex + 1] + 1,
                    previous[hypothesisIndex] + substitutionCost
                )
            }
            previous = current
        }
        return Double(previous[hypothesis.count]) / Double(reference.count)
    }

    private static func multisetRetentionRate(
        reference: [String],
        hypothesis: [String]
    ) -> Double {
        guard !reference.isEmpty else { return 0 }
        var available = Dictionary(hypothesis.map { ($0, 1) }, uniquingKeysWith: +)
        var retained = 0
        for word in reference {
            guard let count = available[word], count > 0 else { continue }
            retained += 1
            available[word] = count - 1
        }
        return Double(retained) / Double(reference.count)
    }

    private static func subtractingMultiset(
        _ values: [String],
        removing removals: [String]
    ) -> [String] {
        var removalCounts = Dictionary(removals.map { ($0, 1) }, uniquingKeysWith: +)
        return values.filter { value in
            guard let count = removalCounts[value], count > 0 else { return true }
            removalCounts[value] = count - 1
            return false
        }
    }
}
