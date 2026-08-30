import Foundation
import Testing
@testable import FerminCore

@Suite("Fermin Code relay routing")
struct FerminCodeRelayRoutingTests {
    private let token = "unit-test-relay-token-0000000000000001"

    @Test
    func canonicalProfilesRouteWithoutCrossingSources() throws {
        #expect(FerminCodeRelayProfile.personal.sources == [.personal])
        #expect(FerminCodeRelayProfile.puky.sources == [.puky])
        #expect(FerminCodeRelayProfile.todo.sources == [.personal, .puky])
        #expect(FerminCodeRelaySource.personal.productionBaseURL.absoluteString ==
            "https://relay.example.com/fermin-code")
        #expect(FerminCodeRelaySource.puky.productionBaseURL.absoluteString ==
            "https://relay.example.com/fermin-code-puky")

        let endpoint = try FerminCodeRelayEndpoint.session("profile::window/one")
        #expect(try endpoint.url(for: .personal).absoluteString ==
            "https://relay.example.com/fermin-code/api/mobile/sessions/profile%3A%3Awindow%2Fone")
        #expect(try endpoint.url(for: .puky).absoluteString ==
            "https://relay.example.com/fermin-code-puky/api/mobile/sessions/profile%3A%3Awindow%2Fone")

        let archive = try FerminCodeRelayEndpoint.archive("profile::window/one")
        #expect(try archive.url(for: .puky).absoluteString ==
            "https://relay.example.com/fermin-code-puky/api/mobile/sessions/profile%3A%3Awindow%2Fone/archive")

        let permanentDelete = try FerminCodeRelayEndpoint.permanentDelete(
            "profile::window/one"
        )
        #expect(try permanentDelete.url(for: .personal).absoluteString ==
            "https://relay.example.com/fermin-code/api/mobile/sessions/profile%3A%3Awindow%2Fone/permanent")

        let pinned = try FerminCodeRelayEndpoint.pinned("profile::window/one")
        #expect(try pinned.url(for: .personal).absoluteString ==
            "https://relay.example.com/fermin-code/api/mobile/sessions/profile%3A%3Awindow%2Fone/pinned")

        let recovery = FerminCodeRelayEndpoint.sessionRecovery(
            queryItems: FerminRelaySessionRecoveryQuery(text: "article-studio").queryItems
        )
        #expect(try recovery.url(for: .personal).absoluteString.contains(
            "/api/mobile/session-recovery?"
        ))
        #expect(try FerminCodeRelayEndpoint.recoverSession().url(for: .puky).absoluteString ==
            "https://relay.example.com/fermin-code-puky/api/mobile/session-recovery/recover")
    }

    @Test
    func todoCannotBecomeANetworkClient() {
        do {
            _ = try FerminCodeRelayClient(profile: .todo, token: token)
            Issue.record("Todo must remain a client-side aggregate")
        } catch let error as FerminRelayHTTPError {
            #expect(error == .aggregateProfileHasNoEndpoint)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func aggregationKeepsIdenticalWindowIDsDistinct() {
        let personal = FerminRelaySession(windowID: "same", sessionID: "p")
        let puky = FerminRelaySession(windowID: "same", sessionID: "r")
        let combined = FerminCodeRelayAggregation.sessions(
            personal: [personal],
            puky: [puky]
        )

        #expect(combined.map(\.source) == [.personal, .puky])
        #expect(Set(combined.map(\.id)).count == 2)
        #expect(combined[0].id == "personal::session::same")
        #expect(combined[1].id == "puky::session::same")
    }
}
