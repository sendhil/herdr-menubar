import Foundation
import Network
import OSLog

protocol HerdrConnection: Sendable {
    func sendLine(_ data: Data) async throws
    func nextLine() async throws -> Data?
    func close() async
}

protocol HerdrConnectionFactory: Sendable {
    func connect(to socketURL: URL) async throws -> any HerdrConnection
}

enum TransportError: Error, Equatable, Sendable {
    case connectionFailed(String)
    case sendFailed(String)
    case receiveFailed(String)
    case invalidFrame
    case concurrentRead
}

struct NWHerdrConnectionFactory: HerdrConnectionFactory {
    func connect(to socketURL: URL) async throws -> any HerdrConnection {
        let networkConnection = NWConnection(
            to: .unix(path: socketURL.path),
            using: .tcp
        )
        let connection = NWHerdrConnection(connection: networkConnection)
        try await connection.start()
        return connection
    }
}

final class NWHerdrConnection: HerdrConnection, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "dev.herdr.menubar.transport")
    private let state = HerdrConnectionState()

    fileprivate init(connection: NWConnection) {
        self.connection = connection
    }

    fileprivate func start() async throws {
        connection.stateUpdateHandler = { [weak self] newState in
            guard let self else { return }
            switch newState {
            case .ready:
                AppLog.transport.debug("Unix socket connection ready")
                Task { await self.state.markReady() }
                self.receiveNext()
            case .failed(let error):
                AppLog.transport.error("Unix socket connection failed: \(error.localizedDescription, privacy: .private)")
                Task { await self.state.fail(.connectionFailed(error.localizedDescription)) }
            case .cancelled:
                AppLog.transport.debug("Unix socket connection closed")
                Task { await self.state.close() }
            default:
                break
            }
        }
        connection.start(queue: queue)

        do {
            try await withTaskCancellationHandler {
                try await state.waitUntilReady()
                try Task.checkCancellation()
            } onCancel: {
                Task { await self.close() }
            }
        } catch where Task.isCancelled {
            await close()
            throw CancellationError()
        }
    }

    func sendLine(_ data: Data) async throws {
        guard !Task.isCancelled else {
            await close()
            throw CancellationError()
        }

        var framedData = data
        if framedData.last != 0x0A {
            framedData.append(0x0A)
        }

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    connection.send(content: framedData, completion: .contentProcessed { error in
                        if let error {
                            continuation.resume(throwing: TransportError.sendFailed(error.localizedDescription))
                        } else {
                            continuation.resume()
                        }
                    })
                }
                try Task.checkCancellation()
            } onCancel: {
                Task { await self.close() }
            }
        } catch where Task.isCancelled {
            await close()
            throw CancellationError()
        }
    }

    func nextLine() async throws -> Data? {
        do {
            return try await withTaskCancellationHandler {
                let line = try await state.nextLine()
                try Task.checkCancellation()
                return line
            } onCancel: {
                Task { await self.close() }
            }
        } catch where Task.isCancelled {
            await close()
            throw CancellationError()
        }
    }

    func close() async {
        guard await state.beginClose() else { return }
        connection.cancel()
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task {
                let shouldContinue = await self.state.receive(data: data, isComplete: isComplete, error: error)
                if shouldContinue {
                    self.receiveNext()
                }
            }
        }
    }
}

private actor HerdrConnectionState {
    private enum ReadTerminal {
        case open
        case closed
        case failed(TransportError)
    }

    private enum StartupState {
        case connecting
        case ready
        case failed(TransportError)
        case closed
    }

    private var framer = JSONLineFramer()
    private var lines: [Data] = []
    private var reader: CheckedContinuation<Data?, any Error>?
    private var readyWaiter: CheckedContinuation<Void, any Error>?
    private var startupState: StartupState = .connecting
    private var readTerminal: ReadTerminal = .open
    private var closeStarted = false

    func beginClose() -> Bool {
        guard !closeStarted else { return false }
        closeStarted = true
        close()
        return true
    }

    func waitUntilReady() async throws {
        switch startupState {
        case .ready:
            return
        case .failed(let error):
            throw error
        case .closed:
            throw CancellationError()
        case .connecting:
            try await withCheckedThrowingContinuation { continuation in
                readyWaiter = continuation
            }
        }
    }

    func markReady() {
        guard case .connecting = startupState else { return }
        startupState = .ready
        readyWaiter?.resume()
        readyWaiter = nil
    }

    func nextLine() async throws -> Data? {
        if !lines.isEmpty {
            return lines.removeFirst()
        }
        switch readTerminal {
        case .closed:
            return nil
        case .failed(let error):
            throw error
        case .open:
            guard reader == nil else {
                throw TransportError.concurrentRead
            }
            return try await withCheckedThrowingContinuation { continuation in
                reader = continuation
            }
        }
    }

    func receive(data: Data?, isComplete: Bool, error: NWError?) -> Bool {
        guard case .open = readTerminal else { return false }

        if let error {
            fail(.receiveFailed(error.localizedDescription))
            return false
        }
        if let data, !data.isEmpty {
            lines.append(contentsOf: framer.append(data))
            deliverLineIfPossible()
        }
        if isComplete {
            do {
                try framer.finish()
                close()
            } catch {
                fail(.invalidFrame)
            }
            return false
        }
        return true
    }

    func fail(_ error: TransportError) {
        if case .connecting = startupState {
            startupState = .failed(error)
            readyWaiter?.resume(throwing: error)
            readyWaiter = nil
        }
        guard case .open = readTerminal else { return }
        readTerminal = .failed(error)
        reader?.resume(throwing: error)
        reader = nil
    }

    func close() {
        if case .connecting = startupState {
            startupState = .closed
            readyWaiter?.resume(throwing: CancellationError())
            readyWaiter = nil
        }
        guard case .open = readTerminal else { return }
        readTerminal = .closed
        if !lines.isEmpty {
            deliverLineIfPossible()
        } else {
            reader?.resume(returning: nil)
            reader = nil
        }
    }

    private func deliverLineIfPossible() {
        guard let reader, !lines.isEmpty else { return }
        self.reader = nil
        reader.resume(returning: lines.removeFirst())
    }
}
