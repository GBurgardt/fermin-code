import Foundation
import SwiftData

struct TweetGenerationBackgroundRequestSnapshot {
    let jobID: UUID
    let sourceTweetURL: String
    let sourceTweetText: String
    let modeRawValue: String
    let intention: String?
    let feedback: String?
    let previousDraft: String?
    let notes: String?
    let model: ShareTweetModel
    let draftCount: Int
    let variationSeed: String
}

struct TweetGenerationBackgroundScheduledTask {
    let taskIdentifier: Int
    let requestBodyFileName: String
}

final class TweetGenerationBackgroundCoordinator: NSObject {
    static let shared = TweetGenerationBackgroundCoordinator()

    private static let sessionIdentifier = "dev.fermincode.mobile.tweet-generation.background"
    private let lock = NSLock()

    private var session: URLSession?
    private var responseBuffers: [Int: Data] = [:]
    private var backgroundCompletionHandler: (() -> Void)?

    private override init() {
        super.init()
    }

    func prepareForProcessLaunch() {
        _ = makeSession()
    }

    func attachBackgroundCompletionHandler(for identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == Self.sessionIdentifier else { return }
        lock.lock()
        backgroundCompletionHandler = completionHandler
        lock.unlock()
        _ = makeSession()
    }

    func schedule(snapshot: TweetGenerationBackgroundRequestSnapshot) async throws -> TweetGenerationBackgroundScheduledTask {
        let secrets = try ShareSecrets.load()
        let systemPrompt = await PromptLibrary.standaloneTweetGeneratorSystemPrompt(remoteURL: secrets.promptApiURL)
        let userInput = PromptLibrary.buildStandaloneTweetGeneratorInput(
            sourceTweetText: snapshot.sourceTweetText,
            sourceTweetURL: snapshot.sourceTweetURL,
            mode: snapshot.modeRawValue,
            intention: snapshot.intention,
            feedback: snapshot.feedback,
            previousDraft: snapshot.previousDraft,
            notes: snapshot.notes,
            variationSeed: snapshot.variationSeed,
            draftCount: snapshot.draftCount
        )

        let client = ShareClaudeClient(apiKey: secrets.anthropicApiKey)
        let preparedRequest = try client.makePreparedRequest(
            systemPrompt: systemPrompt,
            userInput: userInput,
            model: snapshot.model,
            stream: false,
            userAgent: "KyCodeBackgroundTweetJob/1.0"
        )

        let bodyFileURL = try saveRequestBody(preparedRequest.bodyData, jobID: snapshot.jobID)
        let task = makeSession().uploadTask(with: preparedRequest.request, fromFile: bodyFileURL)
        task.taskDescription = snapshot.jobID.uuidString
        task.resume()

        LoggingService.logToFile(
            level: .info,
            message: "[TweetBackground] scheduled job=\(snapshot.jobID.uuidString) task=\(task.taskIdentifier)"
        )

        return TweetGenerationBackgroundScheduledTask(
            taskIdentifier: task.taskIdentifier,
            requestBodyFileName: bodyFileURL.lastPathComponent
        )
    }

    func cancel(jobID: UUID, taskIdentifier: Int?) async {
        let tasks = await allTasks()
        let matchingTasks = tasks.filter {
            $0.taskDescription == jobID.uuidString || (taskIdentifier != nil && $0.taskIdentifier == taskIdentifier)
        }

        for task in matchingTasks {
            task.cancel()
        }

        markJobCancelled(jobID: jobID)
        LoggingService.logToFile(
            level: .info,
            message: "[TweetBackground] cancel requested job=\(jobID.uuidString) matches=\(matchingTasks.count)"
        )
    }

    private func makeSession() -> URLSession {
        lock.lock()
        defer { lock.unlock() }

        if let session {
            return session
        }

        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sharedContainerIdentifier = SharedInbox.appGroupId
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 60 * 60 * 24
        configuration.timeoutIntervalForResource = 60 * 60 * 24
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false

        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        return session
    }

    private func saveRequestBody(_ data: Data, jobID: UUID) throws -> URL {
        let directory = try SharedInbox.ensureDirectory(named: "tweet-generation-requests")
        let url = directory.appendingPathComponent("\(jobID.uuidString).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func appendResponseData(_ data: Data, for taskIdentifier: Int) {
        lock.lock()
        responseBuffers[taskIdentifier, default: Data()].append(data)
        lock.unlock()
    }

    private func consumeResponseData(for taskIdentifier: Int) -> Data {
        lock.lock()
        defer { lock.unlock() }
        let data = responseBuffers.removeValue(forKey: taskIdentifier) ?? Data()
        return data
    }

    private func completeBackgroundEventsIfNeeded() {
        lock.lock()
        let handler = backgroundCompletionHandler
        backgroundCompletionHandler = nil
        lock.unlock()
        handler?()
    }

    private func cleanupRequestFile(named fileName: String?) {
        guard let fileName, !fileName.isEmpty else { return }
        guard let directory = try? SharedInbox.ensureDirectory(named: "tweet-generation-requests") else { return }
        let url = directory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: url)
    }

    private func markJobRunning(jobID: UUID) {
        do {
            let container = try TweetGeneratorModelStore.makeSharedModelContainer()
            let context = ModelContext(container)
            guard let job = fetchJob(id: jobID, in: context), job.status == .queued else { return }
            job.status = .running
            job.updatedAt = Date()
            try context.save()
        } catch {
            LoggingService.logToFile(level: .error, message: "[TweetBackground] mark running failed job=\(jobID.uuidString) error=\(error)")
        }
    }

    private func markJobCancelled(jobID: UUID) {
        do {
            let container = try TweetGeneratorModelStore.makeSharedModelContainer()
            let context = ModelContext(container)
            guard let job = fetchJob(id: jobID, in: context) else { return }
            guard job.status != .completed, job.status != .failed else { return }

            job.status = .cancelled
            job.errorMessage = nil
            job.updatedAt = Date()

            try context.save()
            cleanupRequestFile(named: job.requestBodyFileName)
        } catch {
            LoggingService.logToFile(level: .error, message: "[TweetBackground] cancel failed job=\(jobID.uuidString) error=\(error)")
        }
    }

    private func handleSuccessfulCompletion(jobID: UUID, responseData: Data) {
        do {
            let container = try TweetGeneratorModelStore.makeSharedModelContainer()
            let context = ModelContext(container)
            guard let job = fetchJob(id: jobID, in: context) else {
                LoggingService.logToFile(level: .error, message: "[TweetBackground] missing job on success id=\(jobID.uuidString)")
                return
            }

            let rawModelOutput = try ShareClaudeClient.extractMessageText(from: responseData)
            let drafts = TweetDraftParser.extractTweetDrafts(raw: rawModelOutput, expectedCount: job.draftCount)
            guard !drafts.isEmpty else {
                throw ShareTweetGenerationError.emptyModelOutput
            }

            let conversation = try resolveConversation(for: job, in: context)
            conversation.updatedAt = Date()
            conversation.sourceTweetText = job.sourceTweetTextSnapshot
            conversation.lastModeRawValue = job.modeRawValue
            conversation.lastIntention = job.intention

            for draft in drafts {
                let version = TweetVersion(
                    modeRawValue: job.modeRawValue,
                    intention: job.intention,
                    feedback: job.feedback,
                    modelRawValue: job.modelRawValue,
                    usedFullThread: job.includeFullThread,
                    sourceTweetTextSnapshot: job.sourceTweetTextSnapshot,
                    contentES: draft.es,
                    contentEN: draft.en,
                    conversation: conversation
                )
                context.insert(version)
            }

            job.status = .completed
            job.errorMessage = nil
            job.updatedAt = Date()
            job.completedAt = Date()
            job.conversationID = conversation.id

            try context.save()
            TweetGenerationNotifications.scheduleSuccess(jobID: job.id, conversationID: conversation.id)
            job.notificationSentAt = Date()
            try context.save()

            LoggingService.logToFile(
                level: .info,
                message: "[TweetBackground] completed job=\(job.id.uuidString) drafts=\(drafts.count) conversation=\(conversation.id.uuidString)"
            )
        } catch {
            handleFailedCompletion(jobID: jobID, error: error)
        }
    }

    private func handleFailedCompletion(jobID: UUID, error: Error) {
        do {
            let container = try TweetGeneratorModelStore.makeSharedModelContainer()
            let context = ModelContext(container)
            guard let job = fetchJob(id: jobID, in: context) else {
                LoggingService.logToFile(level: .error, message: "[TweetBackground] missing job on failure id=\(jobID.uuidString) error=\(error)")
                return
            }

            job.status = .failed
            job.errorMessage = error.localizedDescription
            job.updatedAt = Date()

            try context.save()

            TweetGenerationNotifications.scheduleFailure(jobID: job.id, conversationID: job.conversationID)
            job.notificationSentAt = Date()
            try context.save()

            LoggingService.logToFile(level: .error, message: "[TweetBackground] failed job=\(job.id.uuidString) error=\(error)")
        } catch {
            LoggingService.logToFile(level: .error, message: "[TweetBackground] failure persistence failed job=\(jobID.uuidString) error=\(error)")
        }
    }

    private func allTasks() async -> [URLSessionTask] {
        await withCheckedContinuation { continuation in
            makeSession().getAllTasks { tasks in
                continuation.resume(returning: tasks)
            }
        }
    }

    private func fetchJob(id: UUID, in context: ModelContext) -> TweetGenerationJob? {
        let descriptor = FetchDescriptor<TweetGenerationJob>(
            predicate: #Predicate<TweetGenerationJob> { $0.id == id }
        )
        return try? context.fetch(descriptor).first
    }

    private func resolveConversation(for job: TweetGenerationJob, in context: ModelContext) throws -> TweetConversation {
        if let conversationID = job.conversationID {
            let descriptor = FetchDescriptor<TweetConversation>(
                predicate: #Predicate<TweetConversation> { $0.id == conversationID }
            )
            if let existing = try context.fetch(descriptor).first {
                return existing
            }
        }

        let conversation = TweetConversation(
            sourceTweetURL: job.sourceTweetURL,
            sourceTweetText: job.sourceTweetTextSnapshot,
            lastModeRawValue: job.modeRawValue,
            lastIntention: job.intention
        )
        context.insert(conversation)
        try context.save()
        job.conversationID = conversation.id
        return conversation
    }
}

extension TweetGenerationBackgroundCoordinator: URLSessionDataDelegate, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        appendResponseData(data, for: dataTask.taskIdentifier)
        if let description = dataTask.taskDescription,
           let jobID = UUID(uuidString: description) {
            markJobRunning(jobID: jobID)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let description = dataTask.taskDescription,
           let jobID = UUID(uuidString: description) {
            markJobRunning(jobID: jobID)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let responseData = consumeResponseData(for: task.taskIdentifier)

        guard let description = task.taskDescription, let jobID = UUID(uuidString: description) else {
            LoggingService.logToFile(level: .error, message: "[TweetBackground] missing taskDescription task=\(task.taskIdentifier)")
            return
        }

        do {
            let container = try TweetGeneratorModelStore.makeSharedModelContainer()
            let context = ModelContext(container)
            let job = fetchJob(id: jobID, in: context)
            cleanupRequestFile(named: job?.requestBodyFileName)
        } catch {
            LoggingService.logToFile(level: .error, message: "[TweetBackground] cleanup lookup failed job=\(jobID.uuidString) error=\(error)")
        }

        if let nsError = error as NSError?,
           nsError.domain == NSURLErrorDomain,
           nsError.code == NSURLErrorCancelled {
            markJobCancelled(jobID: jobID)
            return
        }

        if let error {
            handleFailedCompletion(jobID: jobID, error: error)
            return
        }

        if let http = task.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            let body = responseData.isEmpty ? nil : String(data: responseData, encoding: .utf8)
            let responseError = ShareHTTPError(statusCode: http.statusCode, service: "Anthropic", body: body)
            handleFailedCompletion(jobID: jobID, error: responseError)
            return
        }

        handleSuccessfulCompletion(jobID: jobID, responseData: responseData)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        completeBackgroundEventsIfNeeded()
    }
}
