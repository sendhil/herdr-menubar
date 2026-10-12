import AppKit

/// Uses the same presentation and actions as the native status item.
@MainActor
final class DetachedMenuController {
    typealias Show = ([StatusMenuNode], @escaping (StatusMenuAction) -> Void) -> Void
    private let present: Show
    private let cancel: () -> Void
    private let action: (StatusMenuAction) -> Void
    private var latest: StatusItemPresentation?
    private var tracking: UUID?
    private var stopped = false

    init(show: @escaping Show, cancel: @escaping () -> Void, action: @escaping (StatusMenuAction) -> Void) {
        self.present = show
        self.cancel = cancel
        self.action = action
    }

    static func live(action: @escaping (StatusMenuAction) -> Void) -> DetachedMenuController {
        let driver = DetachedMenuDriver()
        return DetachedMenuController(show: { driver.show($0, action: $1) }, cancel: { driver.cancel() }, action: action)
    }

    func apply(_ presentation: StatusItemPresentation) {
        guard !stopped else { return }
        latest = presentation
    }

    func show() {
        guard !stopped, let latest else { return }
        guard tracking == nil else { cancel(); return }
        let token = UUID()
        tracking = token
        defer { tracking = nil }
        present(latest.menu) { [weak self] action in
            guard let self, !self.stopped, self.tracking == token else { return }
            self.action(action)
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        latest = nil
        tracking = nil
        cancel()
    }
}

@MainActor
private final class DetachedMenuDriver {
    private var menu: NSMenu?
    private var renderer: NativeStatusMenuRenderer?

    func show(_ nodes: [StatusMenuNode], action: @escaping (StatusMenuAction) -> Void) {
        let renderer = NativeStatusMenuRenderer(action: action)
        self.renderer = renderer
        let menu = renderer.makeMenu(nodes)
        self.menu = menu
        defer { self.menu = nil; self.renderer = nil }
        var point = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
            point.x = min(max(point.x - 8, screen.frame.minX + 8), screen.frame.maxX - 8)
            point.y = min(point.y - 12, screen.frame.maxY - 36)
        }
        NSApp.activate(ignoringOtherApps: true)
        menu.popUp(positioning: nil, at: point, in: nil)
    }

    func cancel() { menu?.cancelTracking() }
}
