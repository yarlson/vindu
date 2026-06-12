import AppKit
import VinduCore

/// Menu bar presence: lets someone who knows no chords see that vindu is
/// running, pause/resume tiling, open the keybinding cheat sheet or config
/// file, and quit. Hidden via `misc:menu_bar = false`.
final class StatusItem: NSObject {
    var onPauseToggle: (() -> Void)?
    var onShowKeybindings: (() -> Void)?
    var onOpenConfig: (() -> Void)?
    var onQuit: (() -> Void)?

    private var item: NSStatusItem?
    private var pauseMenuItem: NSMenuItem?
    private var paused = false

    func setVisible(_ visible: Bool) {
        if visible {
            guard item == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            if let button = item.button {
                button.image = NSImage(systemSymbolName: "rectangle.split.2x1",
                                       accessibilityDescription: "vindu")
                if button.image == nil { button.title = "⊞" }
            }
            item.menu = buildMenu()
            self.item = item
            refresh()
        } else if let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
            pauseMenuItem = nil
        }
    }

    func update(paused: Bool) {
        self.paused = paused
        refresh()
    }

    /// The icon dims while tiling is paused, so the state is visible at a glance.
    private func refresh() {
        item?.button?.appearsDisabled = paused
        pauseMenuItem?.title = paused ? "Resume Tiling" : "Pause Tiling"
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let header = NSMenuItem(title: "vindu \(VinduVersion.string)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let pause = addItem(to: menu, title: "Pause Tiling", action: #selector(pauseClicked))
        pauseMenuItem = pause
        addItem(to: menu, title: "Keybindings…", action: #selector(keybindingsClicked))
        addItem(to: menu, title: "Open Config File", action: #selector(configClicked))
        menu.addItem(.separator())
        addItem(to: menu, title: "Quit vindu", action: #selector(quitClicked))
        return menu
    }

    @discardableResult
    private func addItem(to menu: NSMenu, title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    @objc private func pauseClicked() { onPauseToggle?() }
    @objc private func keybindingsClicked() { onShowKeybindings?() }
    @objc private func configClicked() { onOpenConfig?() }
    @objc private func quitClicked() { onQuit?() }
}
