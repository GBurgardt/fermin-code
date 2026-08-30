import Foundation

enum SharedInbox {
    static let appGroupId = (Bundle.main.object(forInfoDictionaryKey: "FerminCodeAppGroup") as? String)
        ?? "group.dev.fermincode.mobile"

    static func containerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId)
    }

    static func ensureDirectory(named name: String) throws -> URL {
        guard let container = containerURL() else {
            throw NSError(domain: "SharedInbox", code: 1)
        }
        let directory = container.appendingPathComponent(name, isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }
}
