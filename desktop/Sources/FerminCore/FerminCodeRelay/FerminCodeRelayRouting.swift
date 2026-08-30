import Foundation

public enum FerminCodeRelayProfile: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case personal
    case puky
    case todo = "all"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .personal: return "Primary"
        case .puky: return "Secondary"
        case .todo: return "All"
        }
    }

    public var sources: [FerminCodeRelaySource] {
        switch self {
        case .personal: return [.personal]
        case .puky: return [.puky]
        case .todo: return [.personal, .puky]
        }
    }

    public var singleSource: FerminCodeRelaySource? {
        sources.count == 1 ? sources[0] : nil
    }

    public func accepts(_ source: FerminCodeRelaySource) -> Bool {
        sources.contains(source)
    }
}

public enum FerminCodeRelaySource: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case personal
    case puky

    public var id: String { rawValue }

    public static let personalProductionURLString = configuredURL(
        environmentKey: "FERMIN_CODE_PRIMARY_RELAY_URL",
        infoKey: "FerminCodePrimaryRelayURL",
        fallback: "https://relay.example.com/fermin-code"
    )
    public static let pukyProductionURLString = configuredURL(
        environmentKey: "FERMIN_CODE_SECONDARY_RELAY_URL",
        infoKey: "FerminCodeSecondaryRelayURL",
        fallback: "https://relay.example.com/fermin-code-puky"
    )

    private static func configuredURL(
        environmentKey: String,
        infoKey: String,
        fallback: String
    ) -> String {
        let environmentValue = ProcessInfo.processInfo.environment[environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let environmentValue, !environmentValue.isEmpty {
            return environmentValue
        }
        let infoValue = (Bundle.main.object(forInfoDictionaryKey: infoKey) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let infoValue, !infoValue.isEmpty {
            return infoValue
        }
        return fallback
    }

    public var profile: FerminCodeRelayProfile {
        switch self {
        case .personal: return .personal
        case .puky: return .puky
        }
    }

    public var displayName: String { profile.displayName }

    public var productionBaseURL: URL {
        let rawValue: String
        switch self {
        case .personal: rawValue = Self.personalProductionURLString
        case .puky: rawValue = Self.pukyProductionURLString
        }
        guard let url = URL(string: rawValue) else {
            preconditionFailure("Invalid built-in relay URL")
        }
        return url
    }
}

public enum FerminCodeRelayRoutingError: Error, Equatable, Sendable {
    case aggregateProfileHasNoEndpoint
    case emptyPathComponent
    case invalidEndpoint
}

public struct FerminCodeRelaySessionRoute: Codable, Hashable, Sendable, Identifiable {
    public let source: FerminCodeRelaySource
    public let windowID: String

    public init(source: FerminCodeRelaySource, windowID: String) throws {
        let normalizedWindowID = windowID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedWindowID.isEmpty else {
            throw FerminCodeRelayRoutingError.emptyPathComponent
        }
        self.source = source
        self.windowID = normalizedWindowID
    }

    public var id: String {
        "\(source.rawValue)::session::\(windowID)"
    }
}

public struct FerminCodeRelayEndpoint: Hashable, Sendable {
    fileprivate let pathComponents: [String]
    fileprivate let queryItems: [URLQueryItem]

    private init(pathComponents: [String], queryItems: [URLQueryItem] = []) {
        self.pathComponents = pathComponents
        self.queryItems = queryItems
    }

    public static let sessions = FerminCodeRelayEndpoint(
        pathComponents: ["api", "mobile", "sessions"]
    )
    public static let health = FerminCodeRelayEndpoint(pathComponents: ["healthz"])
    public static let stream = FerminCodeRelayEndpoint(
        pathComponents: ["api", "mobile", "stream"]
    )
    public static let projects = FerminCodeRelayEndpoint(
        pathComponents: ["api", "mobile", "projects"]
    )
    public static let sessionHistory = FerminCodeRelayEndpoint(
        pathComponents: ["api", "mobile", "session-history"]
    )
    public static let sessionRecovery = FerminCodeRelayEndpoint(
        pathComponents: ["api", "mobile", "session-recovery"]
    )
    public static let promptImproverPreference = FerminCodeRelayEndpoint(
        pathComponents: ["api", "mobile", "preferences", "prompt-improver"]
    )

    public static func session(_ windowID: String) throws -> FerminCodeRelayEndpoint {
        try endpoint(["api", "mobile", "sessions", validated(windowID)])
    }

    public static func archive(_ windowID: String) throws -> FerminCodeRelayEndpoint {
        try endpoint(["api", "mobile", "sessions", validated(windowID), "archive"])
    }

    public static func permanentDelete(_ windowID: String) throws -> FerminCodeRelayEndpoint {
        try endpoint(["api", "mobile", "sessions", validated(windowID), "permanent"])
    }

    public static func message(_ windowID: String) throws -> FerminCodeRelayEndpoint {
        try endpoint(["api", "mobile", "sessions", validated(windowID), "message"])
    }

    public static func steer(_ windowID: String) throws -> FerminCodeRelayEndpoint {
        try endpoint(["api", "mobile", "sessions", validated(windowID), "steer"])
    }

    public static func interrupt(_ windowID: String) throws -> FerminCodeRelayEndpoint {
        try endpoint(["api", "mobile", "sessions", validated(windowID), "interrupt"])
    }

    public static func models(_ windowID: String) throws -> FerminCodeRelayEndpoint {
        try endpoint(["api", "mobile", "sessions", validated(windowID), "models"])
    }

    public static func modelSettings(_ windowID: String) throws -> FerminCodeRelayEndpoint {
        try endpoint(["api", "mobile", "sessions", validated(windowID), "model-settings"])
    }

    public static func runMode(_ windowID: String) throws -> FerminCodeRelayEndpoint {
        try endpoint(["api", "mobile", "sessions", validated(windowID), "run-mode"])
    }

    public static func features(_ windowID: String) throws -> FerminCodeRelayEndpoint {
        try endpoint(["api", "mobile", "sessions", validated(windowID), "features"])
    }

    public static func rename(_ windowID: String) throws -> FerminCodeRelayEndpoint {
        try endpoint(["api", "mobile", "sessions", validated(windowID), "rename"])
    }

    public static func minimized(
        _ windowID: String,
        minimized: Bool
    ) throws -> FerminCodeRelayEndpoint {
        try endpoint([
            "api", "mobile", "sessions", validated(windowID),
            minimized ? "minimize" : "restore",
        ])
    }

    public static func pinned(_ windowID: String) throws -> FerminCodeRelayEndpoint {
        try endpoint(["api", "mobile", "sessions", validated(windowID), "pinned"])
    }

    public static func createSubagent(_ windowID: String) throws -> FerminCodeRelayEndpoint {
        try endpoint(["api", "mobile", "sessions", validated(windowID), "create-subagent"])
    }

    public static func retryPromptTransform(
        windowID: String,
        messageID: String
    ) throws -> FerminCodeRelayEndpoint {
        try endpoint([
            "api", "mobile", "sessions", validated(windowID), "messages",
            validated(messageID), "retry-prompt-transform",
        ])
    }

    public static func uploadAttachment(_ windowID: String) throws -> FerminCodeRelayEndpoint {
        try endpoint(["api", "mobile", "sessions", validated(windowID), "attachments"])
    }

    public static let filePreview = FerminCodeRelayEndpoint(
        pathComponents: ["api", "mobile", "file-preview"]
    )

    public static func attachmentContent(path: String) throws -> FerminCodeRelayEndpoint {
        let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw FerminCodeRelayRoutingError.emptyPathComponent
        }
        return FerminCodeRelayEndpoint(
            pathComponents: ["api", "mobile", "attachments", "content"],
            queryItems: [URLQueryItem(name: "path", value: normalized)]
        )
    }

    public static func sessionHistory(queryItems: [URLQueryItem]) -> FerminCodeRelayEndpoint {
        FerminCodeRelayEndpoint(
            pathComponents: ["api", "mobile", "session-history"],
            queryItems: queryItems
        )
    }

    public static func resumeHistory() -> FerminCodeRelayEndpoint {
        FerminCodeRelayEndpoint(
            pathComponents: ["api", "mobile", "session-history", "resume"]
        )
    }

    public static func sessionRecovery(queryItems: [URLQueryItem]) -> FerminCodeRelayEndpoint {
        FerminCodeRelayEndpoint(
            pathComponents: ["api", "mobile", "session-recovery"],
            queryItems: queryItems
        )
    }

    public static func recoverSession() -> FerminCodeRelayEndpoint {
        FerminCodeRelayEndpoint(
            pathComponents: ["api", "mobile", "session-recovery", "recover"]
        )
    }

    public func url(for source: FerminCodeRelaySource) throws -> URL {
        guard var components = URLComponents(
            url: source.productionBaseURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw FerminCodeRelayRoutingError.invalidEndpoint
        }
        let encoded = try pathComponents.map(Self.percentEncodedPathComponent)
        let basePath = components.percentEncodedPath.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        components.percentEncodedPath = "/" + ([basePath] + encoded)
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url,
              Self.isAllowedRelayURL(url) else {
            throw FerminCodeRelayRoutingError.invalidEndpoint
        }
        return url
    }

    private static func isAllowedRelayURL(_ url: URL) -> Bool {
        guard url.user == nil, url.password == nil, url.fragment == nil,
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(), !host.isEmpty else {
            return false
        }
        if scheme == "https" { return true }
        guard scheme == "http" else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private static func endpoint(_ components: [String]) throws -> FerminCodeRelayEndpoint {
        guard !components.contains(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            throw FerminCodeRelayRoutingError.emptyPathComponent
        }
        return FerminCodeRelayEndpoint(pathComponents: components)
    }

    private static func validated(_ component: String) throws -> String {
        let normalized = component.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw FerminCodeRelayRoutingError.emptyPathComponent
        }
        return normalized
    }

    private static func percentEncodedPathComponent(_ component: String) throws -> String {
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-._~")
        )
        guard let encoded = component.addingPercentEncoding(withAllowedCharacters: allowed),
              !encoded.isEmpty else {
            throw FerminCodeRelayRoutingError.invalidEndpoint
        }
        return encoded
    }
}

public struct FerminCodeRelaySourcedSession: Codable, Hashable, Sendable, Identifiable {
    public let source: FerminCodeRelaySource
    public let session: FerminRelaySession

    public init(source: FerminCodeRelaySource, session: FerminRelaySession) {
        self.source = source
        self.session = session
    }

    public var id: String {
        "\(source.rawValue)::session::\(session.windowID)"
    }
}

public enum FerminCodeRelayAggregation {
    public static func sessions(
        personal: [FerminRelaySession],
        puky: [FerminRelaySession]
    ) -> [FerminCodeRelaySourcedSession] {
        personal.map { FerminCodeRelaySourcedSession(source: .personal, session: $0) }
            + puky.map { FerminCodeRelaySourcedSession(source: .puky, session: $0) }
    }
}
