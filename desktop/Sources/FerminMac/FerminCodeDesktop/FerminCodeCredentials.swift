import Darwin
import Foundation
import FerminCore

protocol FerminCodeCredentialVault: Sendable {
    func read() throws -> String?
    func save(_ token: String) throws
    func delete() throws
}

extension TokenVault: FerminCodeCredentialVault {}

enum FerminCodeCredentialError: LocalizedError, Equatable {
    case bootstrapNotRegularFile
    case bootstrapWrongOwner
    case bootstrapInsecurePermissions
    case bootstrapTooLarge
    case bootstrapUnreadable
    case bootstrapEmpty

    var errorDescription: String? {
        switch self {
        case .bootstrapNotRegularFile:
            return "El archivo bootstrap-token no es un archivo regular."
        case .bootstrapWrongOwner:
            return "El archivo bootstrap-token pertenece a otro usuario."
        case .bootstrapInsecurePermissions:
            return "El archivo bootstrap-token debe tener permisos 0600."
        case .bootstrapTooLarge:
            return "El archivo bootstrap-token es demasiado grande."
        case .bootstrapUnreadable:
            return "No se pudo leer el archivo bootstrap-token."
        case .bootstrapEmpty:
            return "El archivo bootstrap-token está vacío."
        }
    }
}

struct FerminCodeCredentialSnapshot: Sendable, Equatable {
    private let tokens: [FerminCodeRelaySource: String]
    let importedSources: Set<FerminCodeRelaySource>

    init(
        tokens: [FerminCodeRelaySource: String],
        importedSources: Set<FerminCodeRelaySource> = []
    ) {
        self.tokens = tokens
        self.importedSources = importedSources
    }

    func token(for source: FerminCodeRelaySource) -> String? {
        tokens[source]
    }

    func hasToken(for source: FerminCodeRelaySource) -> Bool {
        token(for: source) != nil
    }
}

actor FerminCodeCredentialStore {
    // A separately identified build must not read or replace another app's token.
    static let keychainService = "\(Bundle.main.bundleIdentifier ?? "dev.fermincode.desktop").relay.v1"

    private let vaults: [FerminCodeRelaySource: any FerminCodeCredentialVault]
    private let bootstrapDirectory: URL

    init(
        vaults: [FerminCodeRelaySource: any FerminCodeCredentialVault],
        bootstrapDirectory: URL
    ) {
        self.vaults = vaults
        self.bootstrapDirectory = bootstrapDirectory
    }

    init() {
        let fileManager = FileManager.default
        vaults = Dictionary(uniqueKeysWithValues: FerminCodeRelaySource.allCases.map { source in
            (
                source,
                TokenVault(
                    service: Self.keychainService,
                    account: "\(source.rawValue)-bearer"
                ) as any FerminCodeCredentialVault
            )
        })
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
        bootstrapDirectory = applicationSupport.appendingPathComponent(
            "dev.kycode.FerminCodeMac",
            isDirectory: true
        )
    }

    func load(importBootstrap: Bool = true) throws -> FerminCodeCredentialSnapshot {
        var tokens = try readTokens()
        let imported = importBootstrap ? try importBootstrapTokens(into: &tokens) : []
        return FerminCodeCredentialSnapshot(tokens: tokens, importedSources: imported)
    }

    func save(_ token: String, for source: FerminCodeRelaySource) throws {
        guard let vault = vaults[source] else { return }
        try vault.save(token)
    }

    func delete(for source: FerminCodeRelaySource) throws {
        guard let vault = vaults[source] else { return }
        try vault.delete()
    }

    private func readTokens() throws -> [FerminCodeRelaySource: String] {
        var result: [FerminCodeRelaySource: String] = [:]
        for source in FerminCodeRelaySource.allCases {
            guard let rawToken = try vaults[source]?.read() else { continue }
            let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty {
                result[source] = token
            }
        }
        return result
    }

    private func importBootstrapTokens(
        into tokens: inout [FerminCodeRelaySource: String]
    ) throws -> Set<FerminCodeRelaySource> {
        var imported = Set<FerminCodeRelaySource>()

        for source in FerminCodeRelaySource.allCases where tokens[source] == nil {
            let sourceURL = bootstrapDirectory.appendingPathComponent(
                "bootstrap-token-\(source.rawValue)",
                isDirectory: false
            )
            guard FileManager.default.fileExists(atPath: sourceURL.path) else { continue }
            let token = try Self.readSecureBootstrapToken(at: sourceURL)
            try vaults[source]?.save(token)
            tokens[source] = token
            imported.insert(source)
            try FileManager.default.removeItem(at: sourceURL)
        }

        let missingSources = FerminCodeRelaySource.allCases.filter { tokens[$0] == nil }
        let sharedURL = bootstrapDirectory.appendingPathComponent(
            "bootstrap-token",
            isDirectory: false
        )
        if !missingSources.isEmpty, FileManager.default.fileExists(atPath: sharedURL.path) {
            let token = try Self.readSecureBootstrapToken(at: sharedURL)
            for source in missingSources {
                try vaults[source]?.save(token)
                tokens[source] = token
                imported.insert(source)
            }
            try FileManager.default.removeItem(at: sharedURL)
        }

        return imported
    }

    static func readSecureBootstrapToken(at url: URL) throws -> String {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            throw FerminCodeCredentialError.bootstrapUnreadable
        }
        guard (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw FerminCodeCredentialError.bootstrapNotRegularFile
        }
        guard metadata.st_uid == geteuid() else {
            throw FerminCodeCredentialError.bootstrapWrongOwner
        }
        guard (metadata.st_mode & mode_t(0o777)) == mode_t(0o600) else {
            throw FerminCodeCredentialError.bootstrapInsecurePermissions
        }
        guard metadata.st_size > 0, metadata.st_size <= 16_384 else {
            throw metadata.st_size <= 0
                ? FerminCodeCredentialError.bootstrapEmpty
                : FerminCodeCredentialError.bootstrapTooLarge
        }
        guard let data = try? Data(contentsOf: url),
              let rawToken = String(data: data, encoding: .utf8) else {
            throw FerminCodeCredentialError.bootstrapUnreadable
        }
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw FerminCodeCredentialError.bootstrapEmpty
        }
        return token
    }
}
