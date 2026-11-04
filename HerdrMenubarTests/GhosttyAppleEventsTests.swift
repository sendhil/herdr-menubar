import Carbon
import Foundation
import XCTest
@testable import HerdrMenubar

@MainActor
final class GhosttyAppleEventsTests: XCTestCase {
    private let process = GhosttyProcessIdentity(pid: 451, launchDate: Date(timeIntervalSince1970: 100))

    func testSnapshotReplyBudgetRejectsOversizedFieldsAndAggregateReplies() async {
        let oversized = String(repeating: "α", count: 131_073)
        let largeTitle = String(repeating: "α", count: 70_000)
        let cases: [(terminals: [GhosttyTerminal], gets: Int)] = [
            ([GhosttyTerminal(id: oversized, title: "project")], 1),
            ([GhosttyTerminal(id: "surface-a", title: oversized)], 3),
            ([GhosttyTerminal(id: "surface-a", title: largeTitle),
              GhosttyTerminal(id: "surface-b", title: largeTitle)], 5)
        ]
        for fixture in cases {
            let sender = FixtureGhosttySender(terminals: fixture.terminals)
            let transport = LiveGhosttyAppleEventTransport(sender: sender)

            do {
                _ = try await transport.listTerminals(process: process, timeout: .milliseconds(500))
                XCTFail("A snapshot exceeding 256 KiB of descriptor replies must be rejected")
            } catch {
                XCTAssertEqual(error as? GhosttyFocusError, .ghosttyControlFailed)
            }
            XCTAssertEqual(sender.getRequestCount, fixture.gets)
            XCTAssertTrue(sender.focusedTerminalIDs.isEmpty)
        }
    }

    func testNonTerminalObjectReferencesFailBeforePropertyRequests() async {
        for referenceClass: UInt32 in [0x47776e64, 0x47746162, 0x63617070] {
            let sender = FixtureGhosttySender(
                terminals: [GhosttyTerminal(id: "surface-a", title: "project")], referenceClass: referenceClass
            )
            let transport = LiveGhosttyAppleEventTransport(sender: sender)

            do {
                _ = try await transport.listTerminals(process: process, timeout: .milliseconds(500))
                XCTFail("Non-terminal specifiers must not form a terminal snapshot")
            } catch {
                XCTAssertEqual(error as? GhosttyFocusError, .ghosttyControlFailed)
            }
            XCTAssertEqual(sender.getRequestCount, 1, "Reject the desired class before property requests")
        }
    }

    func testNonObjectTerminalReferencesFailBeforePropertyRequests() async {
        let sender = FixtureGhosttySender(
            terminals: [GhosttyTerminal(id: "surface-a", title: "project")], nonObjectReferences: true
        )
        let transport = LiveGhosttyAppleEventTransport(sender: sender)

        do {
            _ = try await transport.listTerminals(process: process, timeout: .milliseconds(500))
            XCTFail("Text list entries must not be used as terminal references")
        } catch {
            XCTAssertEqual(error as? GhosttyFocusError, .ghosttyControlFailed)
        }
        XCTAssertEqual(sender.getRequestCount, 1, "Reject the list entry before any property request")
        XCTAssertTrue(sender.focusedTerminalIDs.isEmpty)
    }

    func testCancellationDuringPermissionPreventsFurtherChecksOrConsent() async {
        for cancelDuringPrompt in [false, true] {
            let boundary = FixtureGhosttySender(
                terminals: [], permissionStatuses: [OSStatus(errAEEventWouldRequireUserConsent), noErr]
            )
            let sender = SystemGhosttyAppleEventSender(
                sendEvent: { _, _, _ in throw GhosttyFocusError.ghosttyControlFailed },
                permissionCheck: { target, eventClass, eventID, prompt in
                    let status = boundary.permission(
                        target: target, eventClass: eventClass, eventID: eventID, prompt: prompt
                    )
                    if prompt == cancelDuringPrompt { withUnsafeCurrentTask { $0?.cancel() } }
                    return status
                }
            )
            let transport = LiveGhosttyAppleEventTransport(sender: sender)
            let process = self.process
            let operation = Task { try await transport.authorize(process: process) }
            do {
                try await operation.value
                XCTFail("Cancellation during permission must stop authorization")
            } catch is CancellationError {
                // Expected: no further permission or consent calls.
            } catch {
                XCTFail("Expected CancellationError, got \(error)")
            }
            var expected = [PermissionRequest(
                targetPID: 451, eventClass: 0x636f7265, eventID: 0x67657464, prompt: false
            )]
            if cancelDuringPrompt {
                expected.append(PermissionRequest(
                    targetPID: 451, eventClass: 0x636f7265, eventID: 0x67657464, prompt: true
                ))
            }
            XCTAssertEqual(boundary.permissionRequests, expected)
        }
    }

    func testCancelledTransportRequestsNeverReachPermissionOrFocusBoundaries() async {
        for requestAuthorization in [true, false] {
            let sender = FixtureGhosttySender(
                terminals: [], permissionStatuses: [OSStatus(errAEEventWouldRequireUserConsent), noErr]
            )
            let transport = LiveGhosttyAppleEventTransport(sender: sender)
            let process = self.process
            let operation = Task {
                if requestAuthorization {
                    try await transport.authorize(process: process)
                } else {
                    try await transport.focusTerminal(id: "surface-a", process: process)
                }
            }
            // The task inherits this main actor and cannot start before this synchronous cancellation.
            operation.cancel()
            do {
                try await operation.value
                XCTFail("A cancelled request must not reach any permission or focus boundary")
            } catch is CancellationError {
                // Expected: cancellation must precede side effects.
            } catch {
                XCTFail("Expected CancellationError, got \(error)")
            }
            XCTAssertTrue(sender.permissionRequests.isEmpty)
            XCTAssertTrue(sender.focusedTerminalIDs.isEmpty)
        }
    }

}

// Native event encoding and reply validation.
extension GhosttyAppleEventsTests {
    func testSystemSenderRejectsInvalidTimeoutBeforeOSSend() {
        for timeout: Duration in [.zero, .milliseconds(-1), .seconds(2)] {
            let recorder = SystemEventRecorder()
            let sender = SystemGhosttyAppleEventSender(sendEvent: { recorder.send($0, options: $1, timeout: $2) })

            XCTAssertThrowsError(try sender.send(
                target: NSAppleEventDescriptor(processIdentifier: 451),
                eventClass: 0x636f7265, eventID: 0x67657464,
                direct: NSAppleEventDescriptor(string: "opaque reference"), timeout: timeout
            )) { error in
                XCTAssertEqual(error as? GhosttyFocusError, .ghosttyControlFailed)
            }
            XCTAssertTrue(recorder.requests.isEmpty, "Invalid waits must never reach the OS boundary")
        }
    }

    func testSystemSenderAcceptsVoidReplyOnlyForFocus() {
        let sender = SystemGhosttyAppleEventSender(sendEvent: { _, _, _ in
            NSAppleEventDescriptor.appleEvent(
                withEventClass: 0x61657674, eventID: 0x616e7372, targetDescriptor: nil,
                returnID: Int16(kAutoGenerateReturnID), transactionID: Int32(kAnyTransactionID)
            )
        })
        let target = NSAppleEventDescriptor(processIdentifier: 451)
        let direct = NSAppleEventDescriptor(string: "opaque terminal reference")

        do {
            let result = try sender.send(
                target: target, eventClass: 0x47687374, eventID: 0x46637573, direct: direct, timeout: .seconds(1)
            )
            XCTAssertEqual(result.descriptorType, typeNull)
        } catch {
            XCTFail("An empty successful focus reply must be accepted, got \(error)")
        }
        XCTAssertThrowsError(try sender.send(
            target: target, eventClass: 0x636f7265, eventID: 0x67657464, direct: direct, timeout: .milliseconds(250)
        )) { error in
            XCTAssertEqual(error as? GhosttyFocusError, .ghosttyControlFailed)
        }
    }

    func testSystemSenderRejectsTextErrorNumbersWithoutCoercion() {
        for value in ["0", "-1743", "not-a-status"] {
            let sender = SystemGhosttyAppleEventSender(sendEvent: { _, _, _ in
                let reply = NSAppleEventDescriptor.appleEvent(
                    withEventClass: 0x61657674, eventID: 0x616e7372, targetDescriptor: nil,
                    returnID: Int16(kAutoGenerateReturnID), transactionID: Int32(kAnyTransactionID)
                )
                reply.setParam(NSAppleEventDescriptor(string: value), forKeyword: AEKeyword(keyErrorNumber))
                reply.setParam(NSAppleEventDescriptor(string: "misleading success"), forKeyword: AEKeyword(keyDirectObject))
                return reply
            })

            XCTAssertThrowsError(try sender.send(
                target: NSAppleEventDescriptor(processIdentifier: 451),
                eventClass: 0x636f7265, eventID: 0x67657464,
                direct: NSAppleEventDescriptor(string: "opaque reference"), timeout: .milliseconds(250)
            )) { error in
                XCTAssertEqual(error as? GhosttyFocusError, .ghosttyControlFailed)
            }
        }
    }

    func testSystemSenderMapsThrownOSErrorsWithoutLeakingTransportDetail() {
        let cases: [(NSError, GhosttyFocusError)] = [
            (NSError(domain: NSOSStatusErrorDomain, code: -1743), .automationDenied),
            (NSError(domain: NSOSStatusErrorDomain, code: -1728), .targetGone),
            (NSError(domain: NSOSStatusErrorDomain, code: -600), .targetGone),
            (NSError(domain: NSOSStatusErrorDomain, code: -1712), .lookupTimedOut),
            (NSError(domain: NSOSStatusErrorDomain, code: -1708), .unsupportedGhostty),
            (NSError(domain: NSOSStatusErrorDomain, code: -50), .ghosttyControlFailed),
            (NSError(domain: NSOSStatusErrorDomain, code: Int.max), .ghosttyControlFailed),
            (NSError(domain: "private-transport-domain", code: -1743), .ghosttyControlFailed)
        ]
        for (underlying, expected) in cases {
            let sender = SystemGhosttyAppleEventSender(sendEvent: { _, _, _ in throw underlying })

            XCTAssertThrowsError(try sender.send(
                target: NSAppleEventDescriptor(processIdentifier: 451),
                eventClass: 0x636f7265, eventID: 0x67657464,
                direct: NSAppleEventDescriptor(string: "opaque reference"), timeout: .milliseconds(250)
            )) { error in
                XCTAssertEqual(error as? GhosttyFocusError, expected)
            }
        }
    }

    func testSystemSenderReplyErrorsOverrideDirectPayload() {
        let cases: [(Int32, GhosttyFocusError)] = [
            (-1743, .automationDenied), (-1728, .targetGone), (-600, .targetGone),
            (-1712, .lookupTimedOut), (-1708, .unsupportedGhostty), (-50, .ghosttyControlFailed)
        ]
        for (status, expected) in cases {
            let recorder = SystemEventRecorder(replyError: status)
            let sender = SystemGhosttyAppleEventSender(sendEvent: { recorder.send($0, options: $1, timeout: $2) })

            XCTAssertThrowsError(try sender.send(
                target: NSAppleEventDescriptor(processIdentifier: 451),
                eventClass: 0x636f7265, eventID: 0x67657464,
                direct: NSAppleEventDescriptor(string: "opaque reference"), timeout: .milliseconds(250)
            )) { error in
                XCTAssertEqual(error as? GhosttyFocusError, expected, "Wrong mapping for status \(status)")
            }
            XCTAssertEqual(recorder.requests.count, 1)
        }
    }

    func testSystemSenderForwardsPermissionTargetEventPromptAndStatus() {
        let boundary = FixtureGhosttySender(terminals: [], permissionStatuses: [noErr, OSStatus(-1743)])
        let sender = SystemGhosttyAppleEventSender(
            sendEvent: { _, _, _ in throw GhosttyFocusError.ghosttyControlFailed },
            permissionCheck: { boundary.permission(target: $0, eventClass: $1, eventID: $2, prompt: $3) }
        )
        let target = NSAppleEventDescriptor(processIdentifier: 451)

        XCTAssertEqual(
            sender.permission(target: target, eventClass: 0x636f7265, eventID: 0x67657464, prompt: false), noErr
        )
        XCTAssertEqual(
            sender.permission(target: target, eventClass: 0x47687374, eventID: 0x46637573, prompt: true), OSStatus(-1743)
        )
        XCTAssertEqual(boundary.permissionRequests, [
            PermissionRequest(targetPID: 451, eventClass: 0x636f7265, eventID: 0x67657464, prompt: false),
            PermissionRequest(targetPID: 451, eventClass: 0x47687374, eventID: 0x46637573, prompt: true)
        ])
    }

    func testSystemSenderEncodesNativeEventAndDecodesDirectReply() {
        let recorder = SystemEventRecorder()
        let sender = SystemGhosttyAppleEventSender(sendEvent: { recorder.send($0, options: $1, timeout: $2) })

        do {
            let result = try sender.send(
                target: NSAppleEventDescriptor(processIdentifier: 451),
                eventClass: 0x636f7265, eventID: 0x67657464,
                direct: NSAppleEventDescriptor(string: "opaque reference"), timeout: .milliseconds(250)
            )
            XCTAssertEqual(result.stringValue, "résumé α")
        } catch {
            XCTFail("Expected a native event and decoded reply, got \(error)")
        }
        XCTAssertEqual(recorder.requests, [SystemEventRequest(
            eventClass: 0x636f7265, eventID: 0x67657464, targetPID: 451,
            directText: "opaque reference", options: UInt(kAEWaitReply) | UInt(kAENeverInteract), timeout: 0.25
        )])
    }

}

// Terminal decoding, permission policy, and opaque-ID focus.
extension GhosttyAppleEventsTests {
    func testNonTextIDsAndTitlesRejectTheSnapshotWithoutCoercion() async {
        for property: UInt32 in [0x49442020, 0x706e616d] {
            let sender = FixtureGhosttySender(
                terminals: [GhosttyTerminal(id: "surface-a", title: "project")], nonTextProperty: property
            )
            let transport = LiveGhosttyAppleEventTransport(sender: sender)

            do {
                _ = try await transport.listTerminals(process: process, timeout: .milliseconds(500))
                XCTFail("Non-text property \(property) must not be coerced into a terminal field")
            } catch {
                XCTAssertEqual(error as? GhosttyFocusError, .ghosttyControlFailed)
            }
            XCTAssertTrue(sender.focusedTerminalIDs.isEmpty)
        }
    }

    func testEmptyStableIDRejectsTheSnapshot() async {
        let sender = FixtureGhosttySender(terminals: [GhosttyTerminal(id: "", title: "project")])
        let transport = LiveGhosttyAppleEventTransport(sender: sender)

        do {
            _ = try await transport.listTerminals(process: process, timeout: .milliseconds(500))
            XCTFail("An empty ID must not form a usable terminal snapshot")
        } catch {
            XCTAssertEqual(error as? GhosttyFocusError, .ghosttyControlFailed)
        }
    }

    func testDuplicateTerminalIDsRejectTheSnapshot() async {
        let sender = FixtureGhosttySender(terminals: [
            GhosttyTerminal(id: "same-id", title: "first"),
            GhosttyTerminal(id: "same-id", title: "second")
        ])
        let transport = LiveGhosttyAppleEventTransport(sender: sender)

        do {
            _ = try await transport.listTerminals(process: process, timeout: .milliseconds(500))
            XCTFail("Duplicate stable IDs must not form a usable terminal snapshot")
        } catch {
            XCTAssertEqual(error as? GhosttyFocusError, .ghosttyControlFailed)
        }
        XCTAssertTrue(sender.focusedTerminalIDs.isEmpty)
    }

    func testFocusEncodesExistingTerminalByOpaqueStableID() async {
        let id = #"surface"quoted; not executable"#
        let sender = FixtureGhosttySender(terminals: [GhosttyTerminal(id: id, title: "project")])
        let transport = LiveGhosttyAppleEventTransport(sender: sender)

        do {
            try await transport.focusTerminal(id: id, process: process)
        } catch {
            XCTFail("Expected native focus of the existing stable ID, got \(error)")
        }
        XCTAssertEqual(sender.focusedTerminalIDs, [id])
        XCTAssertTrue(sender.permissionRequests.isEmpty, "Preparation owns permission resolution")
    }

    func testConsentNeededPromptsOnlyForTheRequiredEvent() async {
        let sender = FixtureGhosttySender(terminals: [], permissionStatuses: [OSStatus(-1744), noErr, noErr])
        let transport = LiveGhosttyAppleEventTransport(sender: sender)

        do {
            try await transport.authorize(process: process)
        } catch {
            XCTFail("Expected consent-needed permission to be requested, got \(error)")
        }
        XCTAssertEqual(sender.permissionRequests, [
            PermissionRequest(targetPID: 451, eventClass: 0x636f7265, eventID: 0x67657464, prompt: false),
            PermissionRequest(targetPID: 451, eventClass: 0x636f7265, eventID: 0x67657464, prompt: true),
            PermissionRequest(targetPID: 451, eventClass: 0x47687374, eventID: 0x46637573, prompt: false)
        ])
    }

    func testDeniedPermissionFailsWithoutPromptingOrCheckingFurtherEvents() async {
        let sender = FixtureGhosttySender(terminals: [], permissionStatuses: [OSStatus(-1743)])
        let transport = LiveGhosttyAppleEventTransport(sender: sender)

        do {
            try await transport.authorize(process: process)
            XCTFail("A denied Automation grant must fail")
        } catch {
            XCTAssertEqual(error as? GhosttyFocusError, .automationDenied)
        }
        XCTAssertEqual(sender.permissionRequests, [
            PermissionRequest(targetPID: 451, eventClass: 0x636f7265, eventID: 0x67657464, prompt: false)
        ])
    }

    func testAlreadyAllowedPermissionsCheckBothEventsWithoutPrompting() async {
        let sender = FixtureGhosttySender(terminals: [])
        let transport = LiveGhosttyAppleEventTransport(sender: sender)

        do {
            try await transport.authorize(process: process)
        } catch {
            XCTFail("Expected permission checks for both events without prompting, got \(error)")
        }
        XCTAssertEqual(sender.permissionRequests, [
            PermissionRequest(targetPID: 451, eventClass: 0x636f7265, eventID: 0x67657464, prompt: false),
            PermissionRequest(targetPID: 451, eventClass: 0x47687374, eventID: 0x46637573, prompt: false)
        ])
    }

    func testListPreservesStableIDsAndUnicodeTitles() async {
        let expected = [
            GhosttyTerminal(id: "surface-a", title: "project\tα\nsecond line"),
            GhosttyTerminal(id: "surface-b", title: "herdr-menubar-focus:opaque-token")
        ]
        let sender = FixtureGhosttySender(terminals: expected)
        let transport = LiveGhosttyAppleEventTransport(sender: sender)

        do {
            let actual = try await transport.listTerminals(process: process, timeout: .milliseconds(500))
            XCTAssertEqual(actual, expected)
        } catch {
            XCTFail("Expected decoded terminal identities/titles, got \(error)")
        }
    }
}

private struct SystemEventRequest: Equatable, Sendable {
    let eventClass: UInt32
    let eventID: UInt32
    let targetPID: Int32?
    let directText: String?
    let options: UInt
    let timeout: TimeInterval
}

private final class SystemEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [SystemEventRequest] = []
    private let replyError: Int32?
    var requests: [SystemEventRequest] { lock.withLock { recorded } }

    init(replyError: Int32? = nil) { self.replyError = replyError }

    func send(
        _ event: NSAppleEventDescriptor, options: NSAppleEventDescriptor.SendOptions, timeout: TimeInterval
    ) -> NSAppleEventDescriptor {
        let target = event.attributeDescriptor(forKeyword: AEKeyword(keyAddressAttr))
        let pid: Int32? = target?.descriptorType == typeKernelProcessID && target?.data.count == 4
            ? target?.data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) } : nil
        lock.withLock {
            recorded.append(SystemEventRequest(
                eventClass: event.eventClass, eventID: event.eventID, targetPID: pid,
                directText: event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
                options: options.rawValue, timeout: timeout
            ))
        }
        let reply = NSAppleEventDescriptor.appleEvent(
            withEventClass: 0x61657674, eventID: 0x616e7372, targetDescriptor: nil,
            returnID: Int16(kAutoGenerateReturnID), transactionID: Int32(kAnyTransactionID)
        )
        reply.setParam(NSAppleEventDescriptor(string: "résumé α"), forKeyword: AEKeyword(keyDirectObject))
        if let replyError {
            reply.setParam(NSAppleEventDescriptor(int32: replyError), forKeyword: AEKeyword(keyErrorNumber))
        }
        return reply
    }
}

private struct PermissionRequest: Equatable, Sendable {
    let targetPID: Int32
    let eventClass: UInt32
    let eventID: UInt32
    let prompt: Bool
}

/// Fake only the operating-system Apple Event boundary. All descriptors are real.
private final class FixtureGhosttySender: GhosttyAppleEventSending, @unchecked Sendable {
    private let lock = NSLock()
    private let terminals: [GhosttyTerminal]
    private var requests: [PermissionRequest] = []
    private var permissionStatuses: [OSStatus]
    private let nonTextProperty: UInt32?
    private let nonObjectReferences: Bool
    private let referenceClass: UInt32
    private var focusedIDs: [String] = []
    private var getCount = 0

    var permissionRequests: [PermissionRequest] { lock.withLock { requests } }
    var focusedTerminalIDs: [String] { lock.withLock { focusedIDs } }
    var getRequestCount: Int { lock.withLock { getCount } }

    init(
        terminals: [GhosttyTerminal], permissionStatuses: [OSStatus] = [], nonTextProperty: UInt32? = nil,
        nonObjectReferences: Bool = false, referenceClass: UInt32 = 0x4774726d
    ) {
        self.terminals = terminals
        self.permissionStatuses = permissionStatuses
        self.nonTextProperty = nonTextProperty
        self.nonObjectReferences = nonObjectReferences
        self.referenceClass = referenceClass
    }

    func permission(
        target: NSAppleEventDescriptor, eventClass: UInt32, eventID: UInt32, prompt: Bool
    ) -> OSStatus {
        lock.withLock {
            guard target.descriptorType == typeKernelProcessID,
                  target.data.count == MemoryLayout<Int32>.size else { return OSStatus(paramErr) }
            let pid = target.data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
            requests.append(PermissionRequest(
                targetPID: pid, eventClass: eventClass, eventID: eventID, prompt: prompt
            ))
            return permissionStatuses.isEmpty ? noErr : permissionStatuses.removeFirst()
        }
    }

    func send(
        target: NSAppleEventDescriptor, eventClass: UInt32, eventID: UInt32,
        direct: NSAppleEventDescriptor, timeout: Duration
    ) throws -> NSAppleEventDescriptor {
        try lock.withLock {
            guard target.descriptorType == typeKernelProcessID,
                  target.data.count == MemoryLayout<Int32>.size,
                  target.data.withUnsafeBytes({ $0.loadUnaligned(as: Int32.self) }) == 451,
                  timeout > .zero, timeout <= .seconds(1),
                  let record = direct.coerce(toDescriptorType: typeAERecord),
                  let want = record.forKeyword(0x77616e74)?.typeCodeValue else {
                throw GhosttyFocusError.ghosttyControlFailed
            }
            if eventClass == 0x47687374, eventID == 0x46637573 {
                guard want == 0x4774726d,
                      record.forKeyword(0x666f726d)?.enumCodeValue == 0x49442020,
                      record.forKeyword(0x66726f6d)?.descriptorType == typeNull,
                      let id = record.forKeyword(0x73656c64)?.stringValue,
                      terminals.contains(where: { $0.id == id }) else {
                    throw GhosttyFocusError.targetGone
                }
                focusedIDs.append(id)
                return .null()
            }
            guard eventClass == 0x636f7265, eventID == 0x67657464,
                  timeout <= .milliseconds(500) else {
                throw GhosttyFocusError.ghosttyControlFailed
            }
            getCount += 1
            if want == 0x4774726d {
                let reply = NSAppleEventDescriptor.list()
                for (index, terminal) in terminals.enumerated() {
                    let reference = nonObjectReferences
                        ? NSAppleEventDescriptor(string: terminal.id) : try terminalReference(terminal.id)
                    reply.insert(reference, at: index + 1)
                }
                return reply
            }
            guard want == 0x70726f70,
                  let property = record.forKeyword(0x73656c64)?.typeCodeValue,
                  let container = record.forKeyword(0x66726f6d)?.coerce(toDescriptorType: typeAERecord),
                  let id = container.forKeyword(0x73656c64)?.stringValue,
                  let terminal = terminals.first(where: { $0.id == id }) else {
                throw GhosttyFocusError.targetGone
            }
            if property == nonTextProperty { return NSAppleEventDescriptor(int32: 451) }
            switch property {
            case 0x49442020: return NSAppleEventDescriptor(string: terminal.id)
            case 0x706e616d: return NSAppleEventDescriptor(string: terminal.title)
            default: throw GhosttyFocusError.ghosttyControlFailed
            }
        }
    }

    private func terminalReference(_ id: String) throws -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: referenceClass), forKeyword: 0x77616e74)
        record.setDescriptor(NSAppleEventDescriptor(enumCode: 0x49442020), forKeyword: 0x666f726d)
        record.setDescriptor(NSAppleEventDescriptor(string: id), forKeyword: 0x73656c64)
        record.setDescriptor(NSAppleEventDescriptor.null(), forKeyword: 0x66726f6d)
        guard let reference = record.coerce(toDescriptorType: typeObjectSpecifier) else {
            throw GhosttyFocusError.ghosttyControlFailed
        }
        return reference
    }
}
