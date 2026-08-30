import Foundation
import Combine
import SwiftData

enum TweetGenerationJobStatus: String, CaseIterable, Codable {
    case queued
    case running
    case completed
    case failed
    case cancelled

    var displayLabel: String {
        switch self {
        case .queued:
            return "Queued"
        case .running:
            return "Generating"
        case .completed:
            return "Ready"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        }
    }

    var systemImageName: String {
        switch self {
        case .queued:
            return "clock"
        case .running:
            return "sparkles"
        case .completed:
            return "checkmark.circle"
        case .failed:
            return "exclamationmark.triangle"
        case .cancelled:
            return "xmark.circle"
        }
    }

    var isActive: Bool {
        switch self {
        case .queued, .running:
            return true
        case .completed, .failed, .cancelled:
            return false
        }
    }
}

@Model
final class TweetGenerationJob {
    var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var completedAt: Date?
    var notificationSentAt: Date?
    var statusRawValue: String
    var sourceTweetURL: String
    var sourceTweetTextSnapshot: String
    var modeRawValue: String
    var intention: String?
    var feedback: String?
    var previousDraft: String?
    var notes: String?
    var modelRawValue: String
    var includeFullThread: Bool
    var draftCount: Int
    var variationSeed: String
    var conversationID: UUID?
    var backgroundTaskIdentifier: Int?
    var requestBodyFileName: String?
    var errorMessage: String?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        completedAt: Date? = nil,
        notificationSentAt: Date? = nil,
        status: TweetGenerationJobStatus = .queued,
        sourceTweetURL: String,
        sourceTweetTextSnapshot: String,
        modeRawValue: String,
        intention: String? = nil,
        feedback: String? = nil,
        previousDraft: String? = nil,
        notes: String? = nil,
        modelRawValue: String,
        includeFullThread: Bool,
        draftCount: Int,
        variationSeed: String,
        conversationID: UUID? = nil,
        backgroundTaskIdentifier: Int? = nil,
        requestBodyFileName: String? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.notificationSentAt = notificationSentAt
        self.statusRawValue = status.rawValue
        self.sourceTweetURL = sourceTweetURL
        self.sourceTweetTextSnapshot = sourceTweetTextSnapshot
        self.modeRawValue = modeRawValue
        self.intention = intention
        self.feedback = feedback
        self.previousDraft = previousDraft
        self.notes = notes
        self.modelRawValue = modelRawValue
        self.includeFullThread = includeFullThread
        self.draftCount = draftCount
        self.variationSeed = variationSeed
        self.conversationID = conversationID
        self.backgroundTaskIdentifier = backgroundTaskIdentifier
        self.requestBodyFileName = requestBodyFileName
        self.errorMessage = errorMessage
    }
}

extension TweetGenerationJob {
    var status: TweetGenerationJobStatus {
        get { TweetGenerationJobStatus(rawValue: statusRawValue) ?? .queued }
        set { statusRawValue = newValue.rawValue }
    }
}

struct TweetGenerationJobSnapshot: Identifiable, Equatable {
    let id: UUID
    let updatedAt: Date
    let completedAt: Date?
    let status: TweetGenerationJobStatus
    let sourceTweetURL: String
    let sourceTweetTextSnapshot: String
    let modeRawValue: String
    let intention: String?
    let feedback: String?
    let previousDraft: String?
    let notes: String?
    let modelRawValue: String
    let includeFullThread: Bool
    let draftCount: Int
    let variationSeed: String
    let conversationID: UUID?
    let backgroundTaskIdentifier: Int?
    let requestBodyFileName: String?
    let errorMessage: String?

    init(job: TweetGenerationJob) {
        id = job.id
        updatedAt = job.updatedAt
        completedAt = job.completedAt
        status = job.status
        sourceTweetURL = job.sourceTweetURL
        sourceTweetTextSnapshot = job.sourceTweetTextSnapshot
        modeRawValue = job.modeRawValue
        intention = job.intention
        feedback = job.feedback
        previousDraft = job.previousDraft
        notes = job.notes
        modelRawValue = job.modelRawValue
        includeFullThread = job.includeFullThread
        draftCount = job.draftCount
        variationSeed = job.variationSeed
        conversationID = job.conversationID
        backgroundTaskIdentifier = job.backgroundTaskIdentifier
        requestBodyFileName = job.requestBodyFileName
        errorMessage = job.errorMessage
    }

    var statusMessage: String? {
        switch status {
        case .queued:
            return "Queued"
        case .running:
            return "Generating"
        case .completed, .failed:
            return nil
        case .cancelled:
            return "Cancelled"
        }
    }
}

@MainActor
final class TweetGenerationSyncStore: ObservableObject {
    @Published private(set) var refreshSequence = 0

    private let container: ModelContainer?
    private var jobsByID: [UUID: TweetGenerationJobSnapshot] = [:]
    private var latestJobByConversationID: [UUID: TweetGenerationJobSnapshot] = [:]
    private var latestJobByTweetURL: [String: TweetGenerationJobSnapshot] = [:]
    private var pollingTask: Task<Void, Never>?

    init(container: ModelContainer? = try? TweetGeneratorModelStore.makeSharedModelContainer()) {
        self.container = container
    }

    func start() {
        if pollingTask != nil {
            refreshNow()
            return
        }

        refreshNow()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                self?.refreshNow()
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func refreshNow() {
        do {
            guard let container else { return }
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<TweetGenerationJob>(
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            )
            let jobs = try context.fetch(descriptor)
            apply(snapshots: jobs.map(TweetGenerationJobSnapshot.init(job:)))
        } catch {
            LoggingService.logToFile(level: .error, message: "[TweetJobSync] refresh failed: \(error)")
        }
    }

    func upsert(job: TweetGenerationJob) {
        let snapshot = TweetGenerationJobSnapshot(job: job)
        if jobsByID[snapshot.id] == snapshot {
            return
        }
        jobsByID[snapshot.id] = snapshot
        rebuildIndexes(from: Array(jobsByID.values))
        refreshSequence &+= 1
    }

    func snapshot(jobID: UUID) -> TweetGenerationJobSnapshot? {
        jobsByID[jobID]
    }

    func latestJob(conversationID: UUID?, tweetURL: String) -> TweetGenerationJobSnapshot? {
        if let conversationID, let snapshot = latestJobByConversationID[conversationID] {
            return snapshot
        }
        return latestJobByTweetURL[tweetURL]
    }

    func latestJob(conversationID: UUID) -> TweetGenerationJobSnapshot? {
        latestJobByConversationID[conversationID]
    }

    private func apply(snapshots: [TweetGenerationJobSnapshot]) {
        let nextJobsByID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
        guard nextJobsByID != jobsByID else { return }
        jobsByID = nextJobsByID
        rebuildIndexes(from: snapshots)
        refreshSequence &+= 1
    }

    private func rebuildIndexes(from snapshots: [TweetGenerationJobSnapshot]) {
        latestJobByConversationID.removeAll(keepingCapacity: true)
        latestJobByTweetURL.removeAll(keepingCapacity: true)

        for snapshot in snapshots.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            if let conversationID = snapshot.conversationID,
               latestJobByConversationID[conversationID] == nil {
                latestJobByConversationID[conversationID] = snapshot
            }
            if latestJobByTweetURL[snapshot.sourceTweetURL] == nil {
                latestJobByTweetURL[snapshot.sourceTweetURL] = snapshot
            }
        }
    }
}
