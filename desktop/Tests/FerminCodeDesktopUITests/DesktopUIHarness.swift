import XCTest

enum DesktopAX {
    static let root = "fermin.desktop.root"
    static let brand = "fermin.desktop.brand"
    static let profileSelector = "fermin.desktop.profile.selector"
    static let personalProfile = "fermin.desktop.profile.personal"
    static let pukyProfile = "fermin.desktop.profile.puky"
    static let todoProfile = "fermin.desktop.profile.todo"
    static let personalConnection = "fermin.desktop.connection.personal"
    static let pukyConnection = "fermin.desktop.connection.puky"
    static let newSession = "fermin.desktop.session.new"
    static let createSheet = "fermin.desktop.create.sheet"
    static let createName = "fermin.desktop.create.name"
    static let createProject = "fermin.desktop.create.project"
    static let createConfirm = "fermin.desktop.create.confirm"
    static let createCancel = "fermin.desktop.create.cancel"
    static let sessionSearch = "fermin.desktop.session.search"
    static let selectedSession = "fermin.desktop.session.selected"
    static let sessionMore = "fermin.desktop.session.more"
    static let sessionArchive = "fermin.desktop.session.archive"
    static let archiveConfirm = "fermin.desktop.archive.confirm"
    static let composerText = "fermin.desktop.composer.text"
    static let composerSend = "fermin.desktop.composer.send"
    static let transcript = "fermin.desktop.transcript"
    static let pendingCommand = "fermin.desktop.command.pending"
    static let error = "fermin.desktop.error"
    static let emptyCredentials = "fermin.desktop.session.empty.credentials"

    static func connection(_ source: LiveRelaySource) -> String {
        switch source {
        case .personal: return personalConnection
        case .puky: return pukyConnection
        }
    }

    static func profile(_ source: LiveRelaySource) -> String {
        switch source {
        case .personal: return personalProfile
        case .puky: return pukyProfile
        }
    }

    static func rowPrefix(_ source: LiveRelaySource) -> String {
        "fermin.desktop.session.row.\(source.rawValue)."
    }
}

enum LiveRelaySource: String, CaseIterable {
    case personal
    case puky

    var displayName: String {
        switch self {
        case .personal: return "Personal"
        case .puky: return "Puky"
        }
    }
}

final class LiveSessionRecord {
    let source: LiveRelaySource
    let name: String
    let marker: String
    var creationSubmitted = false
    var rowAccessibilityIdentifier: String?
    var archived = false

    init(source: LiveRelaySource, name: String, marker: String) {
        self.source = source
        self.name = name
        self.marker = marker
    }

    var manifestLine: String {
        [
            "source=\(source.rawValue)",
            "name=\(name)",
            "marker=\(marker)",
            "creationSubmitted=\(creationSubmitted)",
            "archived=\(archived)",
            "rowAccessibilityIdentifier=\(rowAccessibilityIdentifier ?? "unavailable")",
        ].joined(separator: " | ")
    }
}

enum DesktopUIHarnessError: LocalizedError {
    case missingElement(String)
    case disabledElement(String)
    case timedOut(String)
    case unexpectedError(String)

    var errorDescription: String? {
        switch self {
        case let .missingElement(value): return "No apareció \(value)."
        case let .disabledElement(value): return "\(value) quedó deshabilitado."
        case let .timedOut(value): return "Se agotó la espera: \(value)."
        case let .unexpectedError(value): return value
        }
    }
}

@MainActor
extension XCTestCase {
    func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @discardableResult
    func waitUntil(
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.25,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        }
        return condition()
    }

    func requireElement(
        _ identifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 15
    ) throws -> XCUIElement {
        let candidate = element(identifier, in: app)
        guard candidate.waitForExistence(timeout: timeout) else {
            throw DesktopUIHarnessError.missingElement(identifier)
        }
        return candidate
    }

    func requireEnabled(
        _ identifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 15
    ) throws -> XCUIElement {
        let candidate = try requireElement(identifier, in: app, timeout: timeout)
        guard waitUntil(timeout: timeout, condition: { candidate.isEnabled }) else {
            throw DesktopUIHarnessError.disabledElement(identifier)
        }
        return candidate
    }

    func replaceText(in element: XCUIElement, with text: String) {
        element.click()
        element.typeKey("a", modifierFlags: .command)
        element.typeText(text)
    }

    func stringValue(of element: XCUIElement) -> String {
        let value = element.value.map(String.init(describing:)) ?? ""
        return "\(element.label) \(value)".trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func exactLabel(_ label: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR value == %@", label, label))
            .firstMatch
    }

    func existingSessionRow(
        named name: String,
        source: LiveRelaySource,
        in app: XCUIApplication
    ) -> XCUIElement? {
        let identified = app.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "identifier BEGINSWITH %@ AND label CONTAINS[c] %@",
                    DesktopAX.rowPrefix(source),
                    name
                )
            )
            .firstMatch
        if identified.exists { return identified }

        let labelledButton = app.buttons
            .matching(
                NSPredicate(
                    format: "label CONTAINS[c] %@ AND label CONTAINS[c] %@",
                    name,
                    source.displayName
                )
            )
            .firstMatch
        return labelledButton.exists ? labelledButton : nil
    }

    func waitForSessionRow(
        named name: String,
        source: LiveRelaySource,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> XCUIElement? {
        var result: XCUIElement?
        _ = waitUntil(timeout: timeout) {
            result = self.existingSessionRow(named: name, source: source, in: app)
            return result != nil
        }
        return result
    }

    func attachRecoveryEvidence(
        app: XCUIApplication,
        records: [LiveSessionRecord],
        reason: String
    ) {
        let manifest = (["reason=\(reason)"] + records.map(\.manifestLine))
            .joined(separator: "\n")
        let manifestAttachment = XCTAttachment(string: manifest)
        manifestAttachment.name = "Fermin Code Desktop live cleanup manifest"
        manifestAttachment.lifetime = .keepAlways
        add(manifestAttachment)

        if app.state != .notRunning {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Fermin Code Desktop cleanup state"
            screenshot.lifetime = .keepAlways
            add(screenshot)

            let hierarchy = XCTAttachment(string: String(app.debugDescription.prefix(120_000)))
            hierarchy.name = "Fermin Code Desktop accessibility hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
    }
}
