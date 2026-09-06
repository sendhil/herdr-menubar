import AppKit

@MainActor
protocol StatusItemDriving: AnyObject {
    func install(delegate: any StatusItemDriverDelegate)
    func applyIcon(
        _ presentation: MenuBarIconPresentation,
        accessibilityValue: String
    )
    func replaceMenu(
        with nodes: [StatusMenuNode],
        action: @escaping (StatusMenuAction) -> Void
    )
    func performClick()
    func cancelTracking()
    func remove()
}

@MainActor
protocol StatusItemDriverDelegate: AnyObject {
    func statusItemMenuWillOpen()
    func statusItemMenuDidClose()
}

@MainActor
final class StatusItemController: StatusItemDriverDelegate {
    private let driver: any StatusItemDriving
    private let action: (StatusMenuAction) -> Void
    private var latest: StatusItemPresentation?
    private var isOpen = false
    private var isDirty = false
    private var isInstalled = false
    private var isStopped = false

    init(
        driver: any StatusItemDriving,
        action: @escaping (StatusMenuAction) -> Void
    ) {
        self.driver = driver
        self.action = action
    }

    func start() {
        guard !isInstalled, !isStopped else { return }
        isInstalled = true
        driver.install(delegate: self)
        if let latest {
            applyToDriver(latest)
        }
    }

    func apply(_ presentation: StatusItemPresentation) {
        guard !isStopped else { return }
        latest = presentation
        guard isInstalled else { return }
        driver.applyIcon(
            presentation.icon,
            accessibilityValue: presentation.accessibilityValue
        )
        guard !isOpen else {
            isDirty = true
            return
        }
        replaceMenu(with: presentation)
    }

    func toggle() {
        guard isInstalled, !isStopped else { return }
        if isOpen {
            driver.cancelTracking()
        } else {
            driver.performClick()
        }
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        isDirty = false
        latest = nil
        guard isInstalled else { return }
        driver.cancelTracking()
        driver.remove()
    }

    func statusItemMenuWillOpen() {
        guard isInstalled, !isStopped else { return }
        if let latest {
            replaceMenu(with: latest)
        }
        isOpen = true
    }

    func statusItemMenuDidClose() {
        guard isInstalled, !isStopped else { return }
        isOpen = false
        guard isDirty, let latest else { return }
        replaceMenu(with: latest)
    }
}

@MainActor
private extension StatusItemController {
    func applyToDriver(_ presentation: StatusItemPresentation) {
        driver.applyIcon(
            presentation.icon,
            accessibilityValue: presentation.accessibilityValue
        )
        replaceMenu(with: presentation)
    }

    func replaceMenu(with presentation: StatusItemPresentation) {
        isDirty = false
        driver.replaceMenu(with: presentation.menu) { [weak self] selectedAction in
            guard let self, !self.isStopped else { return }
            self.action(selectedAction)
        }
    }
}

@MainActor
final class LiveStatusItemDriver: NSObject, StatusItemDriving, NSMenuDelegate {
    private weak var delegate: (any StatusItemDriverDelegate)?
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private let renderer = NativeStatusMenuRenderer { _ in }

    func install(delegate: any StatusItemDriverDelegate) {
        guard statusItem == nil else { return }
        self.delegate = delegate

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        self.menu = menu
    }

    func applyIcon(
        _ presentation: MenuBarIconPresentation,
        accessibilityValue: String
    ) {
        guard let button = statusItem?.button else { return }
        NativeStatusItemIconRenderer.apply(
            presentation,
            accessibilityValue: accessibilityValue,
            to: button
        )
    }

    func replaceMenu(
        with nodes: [StatusMenuNode],
        action: @escaping (StatusMenuAction) -> Void
    ) {
        guard let menu else { return }
        renderer.action = action
        renderer.replaceItems(in: menu, with: nodes)
    }

    func performClick() {
        statusItem?.button?.performClick(nil)
    }

    func cancelTracking() {
        menu?.cancelTracking()
    }

    func remove() {
        guard let statusItem else { return }
        menu?.delegate = nil
        statusItem.menu = nil
        NSStatusBar.system.removeStatusItem(statusItem)
        menu = nil
        self.statusItem = nil
        delegate = nil
    }

    func menuWillOpen(_ menu: NSMenu) {
        delegate?.statusItemMenuWillOpen()
    }

    func menuDidClose(_ menu: NSMenu) {
        delegate?.statusItemMenuDidClose()
    }
}

final class StatusMenuActionToken: NSObject {
    let action: StatusMenuAction

    init(_ action: StatusMenuAction) {
        self.action = action
    }
}

@MainActor
final class NativeStatusMenuRenderer: NSObject {
    var action: (StatusMenuAction) -> Void

    init(action: @escaping (StatusMenuAction) -> Void) {
        self.action = action
    }

    func makeMenu(_ nodes: [StatusMenuNode]) -> NSMenu {
        let menu = NSMenu()
        replaceItems(in: menu, with: nodes)
        return menu
    }

    func replaceItems(in menu: NSMenu, with nodes: [StatusMenuNode]) {
        menu.autoenablesItems = false
        menu.removeAllItems()
        nodes.forEach { menu.addItem(makeItem(for: $0)) }
    }

    @objc func performAction(_ sender: NSMenuItem) {
        guard let token = sender.representedObject as? StatusMenuActionToken else { return }
        action(token.action)
    }
}

@MainActor
private extension NativeStatusMenuRenderer {
    func makeItem(for node: StatusMenuNode) -> NSMenuItem {
        switch node {
        case let .heading(title):
            return textItem(
                title,
                color: .secondaryLabelColor,
                font: .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
            )

        case let .agent(title, subtitle, symbol, quieter, target):
            let item = actionItem(title: title, action: .select(target))
            item.subtitle = subtitle
            item.image = NSImage(
                systemSymbolName: symbol,
                accessibilityDescription: "Agent status"
            )
            item.indentationLevel = 1
            if quieter {
                item.attributedTitle = attributedTitle(
                    title,
                    color: .secondaryLabelColor,
                    font: .menuFont(ofSize: 0)
                )
            }
            return item

        case let .info(title, tone):
            return textItem(
                title,
                color: tone == .secondary ? .secondaryLabelColor : .systemRed,
                font: .menuFont(ofSize: 0)
            )

        case let .toggle(title, isOn, isEnabled, action):
            let item = actionItem(title: title, action: action)
            item.state = isOn ? .on : .off
            item.isEnabled = isEnabled
            return item

        case let .submenu(title, children):
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = makeMenu(children)
            return item

        case let .action(title, state, isEnabled, action):
            let item = actionItem(title: title, action: action)
            item.state = nativeState(state)
            item.isEnabled = isEnabled
            return item

        case .separator:
            return .separator()
        }
    }

    func actionItem(title: String, action: StatusMenuAction) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: #selector(performAction(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = StatusMenuActionToken(action)
        return item
    }

    func textItem(_ title: String, color: NSColor, font: NSFont) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = attributedTitle(title, color: color, font: font)
        return item
    }

    func attributedTitle(_ title: String, color: NSColor, font: NSFont) -> NSAttributedString {
        NSAttributedString(string: title, attributes: [
            .foregroundColor: color,
            .font: font
        ])
    }

    func nativeState(_ state: MenuItemState) -> NSControl.StateValue {
        switch state {
        case .off: .off
        case .on: .on
        case .mixed: .mixed
        }
    }
}

@MainActor
struct NativeStatusItemIconContent: Equatable {
    let opacity: Double
    let title: String
}

@MainActor
enum NativeStatusItemIconRenderer {
    static func content(
        for presentation: MenuBarIconPresentation
    ) -> NativeStatusItemIconContent {
        NativeStatusItemIconContent(
            opacity: presentation.opacity,
            title: presentation.showsAttentionCount
                ? String(presentation.attentionCount)
                : ""
        )
    }

    static func apply(
        _ presentation: MenuBarIconPresentation,
        accessibilityValue: String,
        to button: NSButton
    ) {
        let content = content(for: presentation)
        button.image = makeImage()
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyDown
        button.title = content.title
        button.font = content.title.isEmpty
            ? .systemFont(ofSize: NSFont.systemFontSize)
            : .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        button.alphaValue = content.opacity
        button.setAccessibilityLabel("Herdr")
        button.setAccessibilityValue(accessibilityValue)
        button.toolTip = "Herdr — \(accessibilityValue)"
    }

    private static func makeImage() -> NSImage? {
        guard let terminal = NSImage(
            systemSymbolName: "terminal",
            accessibilityDescription: "Herdr terminal status"
        )?.withSymbolConfiguration(.init(pointSize: 16, weight: .regular)) else {
            return nil
        }

        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            NSColor.black.set()
            terminal.draw(in: NSRect(x: 0, y: 1, width: 18, height: 16))
            return true
        }
        image.isTemplate = true
        return image
    }
}
