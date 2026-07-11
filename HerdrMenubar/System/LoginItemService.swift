import Foundation
import Observation
import OSLog
import ServiceManagement

@MainActor
enum LoginItemRegistrationStatus: Equatable {
    case enabled
    case requiresApproval
    case notRegistered
    case notFound
}

@MainActor
protocol LoginItemBackend: AnyObject {
    var status: LoginItemRegistrationStatus { get }
    func register() throws
    func unregister() throws
}

@MainActor
final class SMAppServiceLoginItemBackend: LoginItemBackend {
    private let service: SMAppService

    init(service: SMAppService = .mainApp) {
        self.service = service
    }

    var status: LoginItemRegistrationStatus {
        switch service.status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notRegistered:
            return .notRegistered
        case .notFound:
            return .notFound
        @unknown default:
            return .notFound
        }
    }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }
}

enum LoginItemStatus: Equatable {
    case enabled
    case requiresApproval
    case disabled
    case unavailable
}

enum LoginItemOperationError: Error, Equatable {
    case busy
}

@MainActor
protocol LoginItemManaging: AnyObject {
    var status: LoginItemStatus { get }
    var isEnabled: Bool { get }
    var isChanging: Bool { get }
    var helpText: String? { get }
    var errorMessage: String? { get }
    func refreshStatus()
    func setEnabled(_ enabled: Bool) async throws
}

@Observable @MainActor
final class LoginItemService: LoginItemManaging {
    private let backend: any LoginItemBackend
    private let errorDisplayDuration: Duration
    private var errorClearTask: Task<Void, Never>?
    private var errorToken: UUID?

    private(set) var status: LoginItemStatus
    private(set) var isChanging = false
    private(set) var errorMessage: String?

    var isEnabled: Bool { status == .enabled }

    var helpText: String? {
        status == .requiresApproval ? "Allow in System Settings" : nil
    }

    init(
        backend: any LoginItemBackend = SMAppServiceLoginItemBackend(),
        errorDisplayDuration: Duration = .seconds(5)
    ) {
        self.backend = backend
        self.errorDisplayDuration = errorDisplayDuration
        status = Self.map(backend.status)
    }

    func refreshStatus() {
        status = Self.map(backend.status)
    }

    func setEnabled(_ enabled: Bool) async throws {
        guard !isChanging else { throw LoginItemOperationError.busy }
        isChanging = true
        clearError()
        await Task.yield()
        defer {
            refreshStatus()
            isChanging = false
        }

        do {
            if enabled {
                try backend.register()
            } else {
                try backend.unregister()
            }
        } catch {
            presentTransientError("Could not update Launch at Login.")
            AppLog.systemActions.error("Login item update failed: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    private func clearError() {
        errorClearTask?.cancel()
        errorClearTask = nil
        errorToken = nil
        errorMessage = nil
    }

    private func presentTransientError(_ message: String) {
        clearError()
        let token = UUID()
        errorToken = token
        errorMessage = message
        errorClearTask = Task { [weak self, errorDisplayDuration] in
            do {
                try await Task.sleep(for: errorDisplayDuration)
            } catch {
                return
            }
            guard self?.errorToken == token else { return }
            self?.errorMessage = nil
            self?.errorToken = nil
            self?.errorClearTask = nil
        }
    }

    private static func map(_ status: LoginItemRegistrationStatus) -> LoginItemStatus {
        switch status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notRegistered:
            return .disabled
        case .notFound:
            return .unavailable
        }
    }
}
