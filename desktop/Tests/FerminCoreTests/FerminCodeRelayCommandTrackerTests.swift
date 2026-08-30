import Foundation
import Testing
@testable import FerminCore

@Suite("Fermin Code durable command tracker")
struct FerminCodeRelayCommandTrackerTests {
    @Test
    func acknowledgementProgressesOnceAndCompletes() async throws {
        let tracker = FerminRelayDurableCommandTracker()
        let context = FerminRelayTrackedCommandContext(
            operation: .sendMessage,
            source: .personal,
            windowID: "window-1"
        )
        let pending = try await tracker.register(ack("command-1"), context: context)
        #expect(pending == .pending(context))
        #expect(await tracker.pendingCount == 1)

        let leased = await tracker.apply(.init(commandID: "command-1", state: .leased))
        #expect(leased == .pending(context))
        let stale = await tracker.apply(.init(commandID: "command-1", state: .accepted))
        #expect(stale == .ignored)
        let completed = await tracker.apply(.init(commandID: "command-1", state: .completed))
        #expect(completed == .completed(context))
        #expect(await tracker.pendingCount == 0)
        #expect(await tracker.apply(.init(commandID: "command-1", state: .failed)) == .ignored)
    }

    @Test
    func terminalBeforeAcknowledgementReattachesOriginalContext() async throws {
        let tracker = FerminRelayDurableCommandTracker()
        let early = await tracker.apply(
            .init(commandID: "command-2", state: .failed, error: "engine unavailable")
        )
        #expect(early == .failed(nil, .failed, "engine unavailable"))

        let context = FerminRelayTrackedCommandContext(
            operation: .createSession,
            source: .puky,
            sessionID: "session-2"
        )
        let attached = try await tracker.register(ack("command-2"), context: context)
        #expect(attached == .failed(context, .failed, "engine unavailable"))
        #expect(await tracker.pendingCount == 0)
    }

    @Test
    func incompleteOrNonDurableAcknowledgementsAreRejected() async {
        let tracker = FerminRelayDurableCommandTracker()
        let context = FerminRelayTrackedCommandContext(
            operation: .rename,
            source: .personal
        )
        do {
            _ = try await tracker.register(
                FerminRelayDurableCommandAcknowledgement(
                    ok: true,
                    commandID: "command-3",
                    commandState: .accepted,
                    inserted: true,
                    durable: false,
                    queuedAt: 100
                ),
                context: context
            )
            Issue.record("Non-durable acknowledgement was accepted")
        } catch let error as FerminRelayDurableCommandError {
            #expect(error == .notDurable)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func pendingCommandsAreCapacityBoundedAndExpire() async throws {
        let tracker = FerminRelayDurableCommandTracker(
            maximumPendingCommands: 1,
            pendingTTL: 5
        )
        let first = FerminRelayTrackedCommandContext(
            operation: .sendMessage,
            source: .personal,
            windowID: "first"
        )
        let second = FerminRelayTrackedCommandContext(
            operation: .sendMessage,
            source: .personal,
            windowID: "second"
        )
        _ = try await tracker.register(ack("capacity-1"), context: first, now: 0)
        do {
            _ = try await tracker.register(ack("capacity-2"), context: second, now: 1)
            Issue.record("Tracker exceeded its pending capacity")
        } catch let error as FerminRelayDurableCommandError {
            #expect(error == .capacityExceeded(maximumPendingCommands: 1))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await tracker.expirePending(now: 5) == [first])
        #expect(await tracker.pendingCount == 0)
        #expect(try await tracker.register(ack("capacity-2"), context: second, now: 5) ==
            .pending(second))
    }

    private func ack(_ commandID: String) -> FerminRelayDurableCommandAcknowledgement {
        FerminRelayDurableCommandAcknowledgement(
            ok: true,
            commandID: commandID,
            commandState: .accepted,
            inserted: true,
            durable: true,
            queuedAt: 1_720_000_000_000
        )
    }
}
