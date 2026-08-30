import Foundation

enum LogLevel: String {
    case info = "INFO"
    case error = "ERROR"
    case debug = "DEBUG"
}

enum LoggingService {
    static let appGroupId = (Bundle.main.object(forInfoDictionaryKey: "FerminCodeAppGroup") as? String)
        ?? "group.dev.fermincode.mobile"

    private enum LogStorage: String {
        case appGroup = "App Group"
        case documents = "Documents"
    }

    private static let logFolderName = "Logs"
    private static let baseFileName = "kycode-share.log"
    private static let testFileName = "logging-test.txt"
    private static let maxFileSizeBytes = 100 * 1024
    private static let maxFiles = 3
    private static let queue = DispatchQueue(label: "dev.fermincode.mobile.logging", qos: .utility)
    private static var didWriteTestFile: Set<LogStorage> = []
    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func logToFile(level: LogLevel, message: String) {
        queue.async {
            let timestamp = dateFormatter.string(from: Date())
            let line = "[\(timestamp)] [\(level.rawValue)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }

            if let logDirectory = logDirectoryURL(for: .appGroup) {
                do {
                    try writeLog(data: data, in: logDirectory, storage: .appGroup)
                    return
                } catch {
                    NSLog("[KyCode] Error al escribir en App Group: \(error.localizedDescription)")
                }
            } else {
                NSLog("[KyCode] Error: Sin acceso al App Group.")
            }

            NSLog("[KyCode] \(line)")

            if let logDirectory = logDirectoryURL(for: .documents) {
                do {
                    try writeLog(data: data, in: logDirectory, storage: .documents)
                } catch {
                    NSLog("[KyCode] Error al escribir en Documents: \(error.localizedDescription)")
                }
            } else {
                NSLog("[KyCode] Error: Sin acceso a Documents.")
            }
        }
    }

    static func readAllLogs() -> String {
        if let logDirectory = logDirectoryURL(for: .appGroup) {
            let output = readLogs(from: logDirectory)
            if !output.isEmpty {
                return output
            }
        }
        if let logDirectory = logDirectoryURL(for: .documents) {
            return readLogs(from: logDirectory)
        }
        return ""
    }

    static func clearLogs() {
        if let logDirectory = logDirectoryURL(for: .appGroup) {
            clearLogs(in: logDirectory)
        }
        if let logDirectory = logDirectoryURL(for: .documents) {
            clearLogs(in: logDirectory)
        }
    }

    private static func logDirectoryURL(for storage: LogStorage) -> URL? {
        switch storage {
        case .appGroup:
            guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
                return nil
            }
            return container.appendingPathComponent(logFolderName, isDirectory: true)
        case .documents:
            guard let container = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
                return nil
            }
            return container.appendingPathComponent(logFolderName, isDirectory: true)
        }
    }

    private static func logFileURL(in directory: URL, index: Int) -> URL {
        if index == 0 {
            return directory.appendingPathComponent(baseFileName)
        }
        let stem = baseFileName.replacingOccurrences(of: ".log", with: "")
        return directory.appendingPathComponent("\(stem).\(index).log")
    }

    private static func ensureDirectoryExists(at url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private static func rotateIfNeeded(addingBytes: Int, in directory: URL) throws {
        let currentURL = logFileURL(in: directory, index: 0)
        let currentSize = (try? currentURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if currentSize + addingBytes <= maxFileSizeBytes {
            return
        }
        if maxFiles <= 1 {
            try? FileManager.default.removeItem(at: currentURL)
            return
        }
        for index in stride(from: maxFiles - 1, through: 1, by: -1) {
            let destination = logFileURL(in: directory, index: index)
            let source = logFileURL(in: directory, index: index - 1)
            if FileManager.default.fileExists(atPath: destination.path) {
                try? FileManager.default.removeItem(at: destination)
            }
            if FileManager.default.fileExists(atPath: source.path) {
                try? FileManager.default.moveItem(at: source, to: destination)
            }
        }
    }

    private static func append(data: Data, to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } else {
            try data.write(to: url, options: .atomic)
        }
    }

    private static func writeLog(data: Data, in directory: URL, storage: LogStorage) throws {
        try ensureDirectoryExists(at: directory)
        try writeTestFileIfNeeded(in: directory, storage: storage)
        try rotateIfNeeded(addingBytes: data.count, in: directory)
        let fileURL = logFileURL(in: directory, index: 0)
        try append(data: data, to: fileURL)
    }

    private static func writeTestFileIfNeeded(in directory: URL, storage: LogStorage) throws {
        if didWriteTestFile.contains(storage) {
            return
        }
        didWriteTestFile.insert(storage)
        let timestamp = dateFormatter.string(from: Date())
        let line = "[\(timestamp)] [TEST] Registro OK (\(storage.rawValue)).\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = directory.appendingPathComponent(testFileName)
        try append(data: data, to: url)
    }

    private static func readLogs(from directory: URL) -> String {
        var output = ""
        for index in stride(from: maxFiles - 1, through: 0, by: -1) {
            let url = logFileURL(in: directory, index: index)
            if let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) {
                output.append(text)
            }
        }
        return output
    }

    private static func clearLogs(in directory: URL) {
        for index in 0..<maxFiles {
            let url = logFileURL(in: directory, index: index)
            try? FileManager.default.removeItem(at: url)
        }
        let testURL = directory.appendingPathComponent(testFileName)
        try? FileManager.default.removeItem(at: testURL)
    }
}
