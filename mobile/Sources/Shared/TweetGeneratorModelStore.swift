import SwiftData

enum TweetGeneratorModelStore {
    static func makeSharedModelContainer() throws -> ModelContainer {
        let schema = Schema([
            TweetConversation.self,
            TweetVersion.self,
            TweetGenerationJob.self,
        ])
        let configuration = ModelConfiguration(
            "TweetGenerator",
            schema: schema,
            groupContainer: .identifier(SharedInbox.appGroupId),
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
