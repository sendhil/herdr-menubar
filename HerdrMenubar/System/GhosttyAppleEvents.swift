import Carbon
import Foundation

/// Descriptors stay on the transport's isolated executor; only typed values cross actors.
protocol GhosttyAppleEventSending: Sendable {
    func permission(target: NSAppleEventDescriptor, eventClass: UInt32, eventID: UInt32, prompt: Bool) -> OSStatus
    func send(
        target: NSAppleEventDescriptor, eventClass: UInt32, eventID: UInt32,
        direct: NSAppleEventDescriptor, timeout: Duration
    ) throws -> NSAppleEventDescriptor
}

/// The closure replaces Foundation's OS send boundary in hermetic tests.
struct SystemGhosttyAppleEventSender: GhosttyAppleEventSending {
    typealias EventSend = @Sendable (
        NSAppleEventDescriptor, NSAppleEventDescriptor.SendOptions, TimeInterval
    ) throws -> NSAppleEventDescriptor

    typealias PermissionCheck = @Sendable (NSAppleEventDescriptor, UInt32, UInt32, Bool) -> OSStatus

    private let sendEvent: EventSend
    private let permissionCheck: PermissionCheck

    init(
        sendEvent: @escaping EventSend,
        permissionCheck: @escaping PermissionCheck = { _, _, _, _ in OSStatus(paramErr) }
    ) {
        self.sendEvent = sendEvent
        self.permissionCheck = permissionCheck
    }

    /// Only the isolated live transport uses these callbacks; test initializers remain hermetic.
    static func live() -> Self {
        Self(
            sendEvent: { event, options, timeout in
                try event.sendEvent(options: options, timeout: timeout)
            },
            permissionCheck: { target, eventClass, eventID, prompt in
                guard let address = target.aeDesc else { return OSStatus(paramErr) }
                return AEDeterminePermissionToAutomateTarget(address, eventClass, eventID, prompt)
            }
        )
    }

    func permission(target: NSAppleEventDescriptor, eventClass: UInt32, eventID: UInt32, prompt: Bool) -> OSStatus {
        permissionCheck(target, eventClass, eventID, prompt)
    }

    func send(
        target: NSAppleEventDescriptor, eventClass: UInt32, eventID: UInt32,
        direct: NSAppleEventDescriptor, timeout: Duration
    ) throws -> NSAppleEventDescriptor {
        guard timeout > .zero, timeout <= .seconds(1) else {
            throw GhosttyFocusError.ghosttyControlFailed
        }
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: eventClass, eventID: eventID, targetDescriptor: target,
            returnID: Int16(kAutoGenerateReturnID), transactionID: Int32(kAnyTransactionID)
        )
        event.setParam(direct, forKeyword: AEKeyword(keyDirectObject))
        let components = timeout.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        let reply: NSAppleEventDescriptor
        do {
            reply = try sendEvent(event, [.waitForReply, .neverInteract], seconds)
        } catch let error as GhosttyFocusError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let underlying = error as NSError
            guard underlying.domain == NSOSStatusErrorDomain, let status = OSStatus(exactly: underlying.code) else {
                throw GhosttyFocusError.ghosttyControlFailed
            }
            throw Self.focusError(for: status)
        }
        if let errorNumber = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber)) {
            guard errorNumber.descriptorType == typeSInt32, errorNumber.data.count == MemoryLayout<Int32>.size else {
                throw GhosttyFocusError.ghosttyControlFailed
            }
            let status = errorNumber.int32Value
            if status != noErr { throw Self.focusError(for: status) }
        }
        guard let result = reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) else {
            if eventClass == 0x47687374, eventID == 0x46637573, reply.descriptorType == typeAppleEvent {
                return .null()
            }
            throw GhosttyFocusError.ghosttyControlFailed
        }
        return result
    }

    private static func focusError(for status: OSStatus) -> GhosttyFocusError {
        switch status {
        case OSStatus(errAEEventNotPermitted): return .automationDenied
        case OSStatus(errAENoSuchObject), OSStatus(procNotFound): return .targetGone
        case OSStatus(errAETimeout): return .lookupTimedOut
        case OSStatus(errAEEventNotHandled): return .unsupportedGhostty
        default: return .ghosttyControlFailed
        }
    }
}

actor LiveGhosttyAppleEventTransport: GhosttyTransporting {
    private static let snapshotReplyLimit = 256 * 1024
    private let sender: any GhosttyAppleEventSending

    init(sender: any GhosttyAppleEventSending = SystemGhosttyAppleEventSender.live()) { self.sender = sender }

    func authorize(process: GhosttyProcessIdentity) async throws {
        try Task.checkCancellation()
        let target = NSAppleEventDescriptor(processIdentifier: process.pid)
        let events: [(UInt32, UInt32)] = [
            (0x636f7265, 0x67657464), // core/getd
            (0x47687374, 0x46637573)  // Ghst/Fcus
        ]
        for (eventClass, eventID) in events {
            var status = sender.permission(
                target: target, eventClass: eventClass, eventID: eventID, prompt: false
            )
            try Task.checkCancellation()
            if status == OSStatus(errAEEventWouldRequireUserConsent) {
                status = sender.permission(
                    target: target, eventClass: eventClass, eventID: eventID, prompt: true
                )
                try Task.checkCancellation()
            }
            if status == OSStatus(errAEEventNotPermitted) {
                throw GhosttyFocusError.automationDenied
            }
            guard status == noErr else { throw GhosttyFocusError.ghosttyControlFailed }
        }
    }

    func listTerminals(process: GhosttyProcessIdentity, timeout: Duration) async throws -> [GhosttyTerminal] {
        var remainingReplyBytes = Self.snapshotReplyLimit
        let deadline = ContinuousClock().now.advanced(by: timeout)
        let allTerminals = try object(
            want: 0x4774726d, form: UInt32(formAbsolutePosition),
            selector: NSAppleEventDescriptor(enumCode: UInt32(kAEAll))
        )
        let references = try get(
            allTerminals, process: process, deadline: deadline, remainingBytes: &remainingReplyBytes
        )
        guard references.descriptorType == typeAEList else {
            throw GhosttyFocusError.ghosttyControlFailed
        }
        var terminals: [GhosttyTerminal] = []
        var ids: Set<String> = []
        for index in 0..<references.numberOfItems {
            guard let reference = references.atIndex(index + 1), reference.descriptorType == typeObjectSpecifier,
                  let record = reference.coerce(toDescriptorType: typeAERecord),
                  let desiredClass = record.forKeyword(AEKeyword(keyAEDesiredClass)),
                  desiredClass.descriptorType == typeType, desiredClass.typeCodeValue == 0x4774726d else {
                throw GhosttyFocusError.ghosttyControlFailed
            }
            let idProperty = try object(
                want: UInt32(typeProperty), form: UInt32(formPropertyID),
                selector: NSAppleEventDescriptor(typeCode: 0x49442020), container: reference
            )
            let titleProperty = try object(
                want: UInt32(typeProperty), form: UInt32(formPropertyID),
                selector: NSAppleEventDescriptor(typeCode: 0x706e616d), container: reference
            )
            let id = try decodeText(get(
                idProperty, process: process, deadline: deadline, remainingBytes: &remainingReplyBytes
            ))
            let title = try decodeText(get(
                titleProperty, process: process, deadline: deadline, remainingBytes: &remainingReplyBytes
            ))
            guard !id.isEmpty, ids.insert(id).inserted else {
                throw GhosttyFocusError.ghosttyControlFailed
            }
            terminals.append(GhosttyTerminal(id: id, title: title))
        }
        return terminals
    }

    private func decodeText(_ descriptor: NSAppleEventDescriptor) throws -> String {
        let textTypes: Set<DescType> = [typeUnicodeText, typeUTF8Text, typeChar]
        guard textTypes.contains(descriptor.descriptorType), let value = descriptor.stringValue else {
            throw GhosttyFocusError.ghosttyControlFailed
        }
        return value
    }

    private func get(
        _ direct: NSAppleEventDescriptor,
        process: GhosttyProcessIdentity,
        deadline: ContinuousClock.Instant,
        remainingBytes: inout Int
    ) throws -> NSAppleEventDescriptor {
        try Task.checkCancellation()
        let remaining = ContinuousClock().now.duration(to: deadline)
        guard remaining > .zero else { throw GhosttyFocusError.lookupTimedOut }
        let reply = try sender.send(
            target: NSAppleEventDescriptor(processIdentifier: process.pid),
            eventClass: 0x636f7265, eventID: 0x67657464, direct: direct,
            timeout: min(.milliseconds(500), remaining)
        )
        let byteCount = reply.data.count
        guard byteCount <= remainingBytes else { throw GhosttyFocusError.ghosttyControlFailed }
        remainingBytes -= byteCount
        return reply
    }

    private func object(
        want: UInt32,
        form: UInt32,
        selector: NSAppleEventDescriptor,
        container: NSAppleEventDescriptor = .null()
    ) throws -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: want), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: form), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(selector, forKeyword: AEKeyword(keyAEKeyData))
        record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        guard let result = record.coerce(toDescriptorType: typeObjectSpecifier) else {
            throw GhosttyFocusError.ghosttyControlFailed
        }
        return result
    }

    func focusTerminal(id: String, process: GhosttyProcessIdentity) async throws {
        try Task.checkCancellation()
        let terminal = try object(
            want: 0x4774726d, form: UInt32(formUniqueID),
            selector: NSAppleEventDescriptor(string: id)
        )
        _ = try sender.send(
            target: NSAppleEventDescriptor(processIdentifier: process.pid),
            eventClass: 0x47687374, eventID: 0x46637573, direct: terminal, timeout: .seconds(1)
        )
    }
}
