import Foundation
import XCTest
@testable import HerdrMenubar

@MainActor
final class GhosttyControlTests: XCTestCase {
    private let process = GhosttyProcessIdentity(pid: 451, launchDate: Date(timeIntervalSince1970: 100))

    func testReplacementBeforeOrDuringListingRejectsTheSnapshot() async throws {
        for replaceDuringList in [false, true] {
            let gate = replaceDuringList ? GhosttyAuthorizationGate() : nil
            let transport = GhosttyControlTransportFake(
                terminals: [GhosttyTerminal(id: "surface-a", title: "project")], listGate: gate
            )
            let apps = GhosttyApplicationsBox([GhosttyRunningApplication(process: process, version: "1.4.0")])
            let control = LiveGhosttyControl(transport: transport, runningApplications: { apps.values })
            let prepared = try await control.prepareForFocus()
            let replacement = GhosttyProcessIdentity(pid: 451, launchDate: Date(timeIntervalSince1970: 200))
            if !replaceDuringList {
                apps.values = [GhosttyRunningApplication(process: replacement, version: "1.4.0")]
            }
            let listing = Task {
                try await control.listTerminals(process: prepared, timeout: .milliseconds(500))
            }
            if let gate {
                await gate.waitUntilEntered()
                apps.values = [GhosttyRunningApplication(process: replacement, version: "1.4.0")]
                gate.release()
            }

            do {
                _ = try await listing.value
                XCTFail("A replacement process must not return terminals under the old identity")
            } catch {
                XCTAssertEqual(error as? GhosttyFocusError, .targetGone)
            }
            let requests = await transport.listRequests
            XCTAssertEqual(requests.count, replaceDuringList ? 1 : 0)
        }
    }

    func testReplacedProcessIsNotFocusedAfterPreparation() async throws {
        let transport = GhosttyControlTransportFake()
        let apps = GhosttyApplicationsBox([GhosttyRunningApplication(process: process, version: "1.4.0")])
        let control = LiveGhosttyControl(transport: transport, runningApplications: { apps.values })
        let prepared = try await control.prepareForFocus()
        let replacement = GhosttyProcessIdentity(pid: 451, launchDate: Date(timeIntervalSince1970: 200))
        apps.values = [GhosttyRunningApplication(process: replacement, version: "1.4.0")]

        do {
            try await control.focusTerminal(id: "surface-a", process: prepared)
            XCTFail("A replaced process must not receive focus")
        } catch {
            XCTAssertEqual(error as? GhosttyFocusError, .targetGone)
        }
        let requests = await transport.focusRequests
        XCTAssertTrue(requests.isEmpty)
    }

    func testFocusForwardsOnlyRequestedStableIDAndPreparedProcess() async throws {
        let transport = GhosttyControlTransportFake()
        let app = GhosttyRunningApplication(process: process, version: "1.4.0")
        let control = LiveGhosttyControl(transport: transport, runningApplications: { [app] })
        let prepared = try await control.prepareForFocus()

        do {
            try await control.focusTerminal(id: "surface-a", process: prepared)
        } catch {
            XCTFail("Expected focus of the requested existing surface, got \(error)")
        }
        let requests = await transport.focusRequests
        XCTAssertEqual(requests, [GhosttyFocusRequest(id: "surface-a", process: process)])
    }

    func testListingReturnsProcessQualifiedTerminalsWithCallerBudget() async throws {
        let terminals = [GhosttyTerminal(id: "surface-a", title: "project")]
        let transport = GhosttyControlTransportFake(terminals: terminals)
        let app = GhosttyRunningApplication(process: process, version: "1.4.0")
        let control = LiveGhosttyControl(transport: transport, runningApplications: { [app] })
        let prepared = try await control.prepareForFocus()

        do {
            let snapshot = try await control.listTerminals(process: prepared, timeout: .milliseconds(500))
            XCTAssertEqual(snapshot, GhosttyTerminalSnapshot(process: process, terminals: terminals))
        } catch {
            XCTFail("Expected process-qualified terminal listing, got \(error)")
        }
        let requests = await transport.listRequests
        XCTAssertEqual(requests, [GhosttyListRequest(process: process, timeout: .milliseconds(500))])
    }

    func testProcessReplacementDuringAuthorizationRejectsPreparedIdentity() async {
        let gate = GhosttyAuthorizationGate()
        let transport = GhosttyControlTransportFake(gate: gate)
        let apps = GhosttyApplicationsBox([GhosttyRunningApplication(process: process, version: "1.4.0")])
        let control = LiveGhosttyControl(transport: transport, runningApplications: { apps.values })
        let preparation = Task { try await control.prepareForFocus() }

        await gate.waitUntilEntered()
        let replacement = GhosttyProcessIdentity(pid: 451, launchDate: Date(timeIntervalSince1970: 200))
        apps.values = [GhosttyRunningApplication(process: replacement, version: "1.4.0")]
        gate.release()

        do {
            _ = try await preparation.value
            XCTFail("A replaced process must not return the old prepared identity")
        } catch {
            XCTAssertEqual(error as? GhosttyFocusError, .targetGone)
        }
        let requests = await transport.authorizationRequests
        XCTAssertEqual(requests, [process])
    }

    func testSupportedRunningInstanceIsPreparedWithPermission() async {
        let transport = GhosttyControlTransportFake()
        let app = GhosttyRunningApplication(process: process, version: "1.4.0")
        let control = LiveGhosttyControl(transport: transport, runningApplications: { [app] })

        do {
            let actual = try await control.prepareForFocus()
            XCTAssertEqual(actual, process)
        } catch {
            XCTFail("Expected the supported running instance to be prepared, got \(error)")
        }
        let requests = await transport.authorizationRequests
        XCTAssertEqual(requests, [process])
    }

    func testMalformedVersionFailsBeforeRequestingPermission() async {
        let transport = GhosttyControlTransportFake()
        let app = GhosttyRunningApplication(process: process, version: "unknown")
        let control = LiveGhosttyControl(transport: transport, runningApplications: { [app] })

        do {
            _ = try await control.prepareForFocus()
            XCTFail("Malformed version metadata must not be treated as a newer Ghostty")
        } catch {
            XCTAssertEqual(error as? GhosttyFocusError, .unsupportedGhostty)
        }
        let requests = await transport.authorizationRequests
        XCTAssertTrue(requests.isEmpty)
    }

    func testUnsupportedVersionFailsBeforeRequestingPermission() async {
        let transport = GhosttyControlTransportFake()
        let app = GhosttyRunningApplication(process: process, version: "1.3.9")
        let control = LiveGhosttyControl(transport: transport, runningApplications: { [app] })

        do {
            _ = try await control.prepareForFocus()
            XCTFail("An unsupported Ghostty version must not be prepared")
        } catch {
            XCTAssertEqual(error as? GhosttyFocusError, .unsupportedGhostty)
        }
        let requests = await transport.authorizationRequests
        XCTAssertTrue(requests.isEmpty, "Version rejection must precede Automation permission")
    }

    func testMissingRunningApplicationFailsWithoutRequestingPermission() async {
        let transport = GhosttyControlTransportFake()
        let control = LiveGhosttyControl(transport: transport, runningApplications: { [] })

        do {
            _ = try await control.prepareForFocus()
            XCTFail("An absent running app must not be prepared")
        } catch {
            XCTAssertEqual(error as? GhosttyFocusError, .ghosttyUnavailable)
        }
        let requests = await transport.authorizationRequests
        XCTAssertEqual(requests, [])
    }
}

private actor GhosttyControlTransportFake: GhosttyTransporting {
    private(set) var authorizationRequests: [GhosttyProcessIdentity] = []
    private let gate: GhosttyAuthorizationGate?
    private let terminals: [GhosttyTerminal]
    private let listGate: GhosttyAuthorizationGate?
    private(set) var listRequests: [GhosttyListRequest] = []
    private(set) var focusRequests: [GhosttyFocusRequest] = []

    init(
        terminals: [GhosttyTerminal] = [], gate: GhosttyAuthorizationGate? = nil,
        listGate: GhosttyAuthorizationGate? = nil
    ) {
        self.terminals = terminals
        self.gate = gate
        self.listGate = listGate
    }

    func authorize(process: GhosttyProcessIdentity) async throws {
        authorizationRequests.append(process)
        await gate?.wait()
    }
    func listTerminals(process: GhosttyProcessIdentity, timeout: Duration) async throws -> [GhosttyTerminal] {
        listRequests.append(GhosttyListRequest(process: process, timeout: timeout))
        await listGate?.wait()
        return terminals
    }
    func focusTerminal(id: String, process: GhosttyProcessIdentity) async throws {
        focusRequests.append(GhosttyFocusRequest(id: id, process: process))
    }
}

private struct GhosttyFocusRequest: Equatable, Sendable {
    let id: String
    let process: GhosttyProcessIdentity
}

private struct GhosttyListRequest: Equatable, Sendable {
    let process: GhosttyProcessIdentity
    let timeout: Duration
}

@MainActor
private final class GhosttyApplicationsBox {
    var values: [GhosttyRunningApplication]
    init(_ values: [GhosttyRunningApplication]) { self.values = values }
}

@MainActor
private final class GhosttyAuthorizationGate {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilEntered() async {
        while !entered { await Task.yield() }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
