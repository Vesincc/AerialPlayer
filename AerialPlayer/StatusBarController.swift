import AppKit
import ServiceManagement

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let controller: WallpaperController
    private let statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let statusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "暂停播放", action: #selector(togglePaused), keyEquivalent: "")
    private let muteItem = NSMenuItem(title: "静音", action: #selector(toggleMuted), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "开机自动启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private let loginApprovalItem = NSMenuItem(title: "在系统设置中允许自动启动…", action: #selector(openLoginItemsSettings), keyEquivalent: "")
    private let speedControl: PlaybackSpeedControl
    private var wallpaperItems: [NSMenuItem] = []
    private var fillItems: [VideoFillMode: NSMenuItem] = [:]
    private var updatingLoginItem = false
    private var menuIsOpen = false
    private var menuNeedsUpdate = false

    init(controller: WallpaperController) {
        self.controller = controller
        speedControl = PlaybackSpeedControl(rate: controller.playbackRate, range: WallpaperController.playbackRateRange)
        super.init()
        buildMenu()
        speedControl.onRateChange = { [weak controller] in controller?.setPlaybackRate($0) }
        controller.onChange = { [weak self] in self?.updateMenu() }
        updateMenu()
    }

    func remove() {
        NSStatusBar.system.removeStatusItem(statusBarItem)
    }

    private func buildMenu() {
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.isEnabled = false
        menu.addItem(statusItem)
        menu.addItem(.separator())
        pauseItem.target = self
        menu.addItem(pauseItem)
        let speed = NSMenuItem()
        speed.view = speedControl
        menu.addItem(speed)
        muteItem.target = self
        menu.addItem(muteItem)
        let fill = NSMenuItem(title: "填充模式", action: nil, keyEquivalent: "")
        let modes = NSMenu()
        modes.autoenablesItems = false
        for mode in VideoFillMode.allCases {
            let option = NSMenuItem(title: mode.title, action: #selector(changeFillMode(_:)), keyEquivalent: "")
            option.target = self
            option.representedObject = mode.rawValue
            modes.addItem(option)
            fillItems[mode] = option
        }
        fill.submenu = modes
        menu.addItem(fill)
        let refresh = NSMenuItem(title: "重新读取当前壁纸", action: #selector(refresh), keyEquivalent: "")
        refresh.target = self
        menu.addItem(refresh)
        menu.addItem(.separator())
        loginItem.target = self
        menu.addItem(loginItem)
        loginApprovalItem.target = self
        menu.addItem(loginApprovalItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 AerialPlayer", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusBarItem.menu = menu
    }

    private func updateMenu() {
        updatePlaybackControls()
        if menuIsOpen {
            menuNeedsUpdate = true
            return
        }
        let symbol = controller.userPaused ? "pause.rectangle" : "play.rectangle"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "AerialPlayer")
        image?.isTemplate = true
        statusBarItem.button?.image = image
        statusBarItem.button?.toolTip = "AerialPlayer · \(controller.statusMessage)"
        statusItem.title = controller.statusMessage
        pauseItem.title = controller.userPaused ? "继续播放" : "暂停播放"
        pauseItem.isEnabled = controller.hasVideo
        updateWallpaperDescriptions()
        updateLoginItem()
    }

    private func updateWallpaperDescriptions() {
        let descriptions = controller.wallpaperDescriptions
        if wallpaperItems.count != descriptions.count {
            wallpaperItems.forEach { menu.removeItem($0) }
            wallpaperItems = descriptions.map { description in
                let item = NSMenuItem(title: description, action: nil, keyEquivalent: "")
                item.isEnabled = false
                return item
            }
            for (index, item) in wallpaperItems.enumerated() {
                menu.insertItem(item, at: index + 1)
            }
        }
        for (item, description) in zip(wallpaperItems, descriptions) {
            item.title = description
        }
    }

    private func updatePlaybackControls() {
        speedControl.update(rate: controller.playbackRate)
        muteItem.state = controller.isMuted ? .on : .off
        for (mode, option) in fillItems {
            option.state = mode == controller.fillMode ? .on : .off
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        updateLoginItem()
        updatePlaybackControls()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        if menuNeedsUpdate {
            menuNeedsUpdate = false
            updateMenu()
        }
    }

    private func updateLoginItem() {
        let status = SMAppService.mainApp.status
        loginItem.title = status == .requiresApproval ? "开机自动启动（待系统允许）" : "开机自动启动"
        loginItem.isEnabled = !updatingLoginItem
        switch status {
        case .enabled: loginItem.state = .on
        case .requiresApproval: loginItem.state = .mixed
        case .notRegistered, .notFound: loginItem.state = .off
        @unknown default:
            loginItem.state = .off
            loginItem.isEnabled = false
        }
        loginApprovalItem.isHidden = status != .requiresApproval
        loginApprovalItem.isEnabled = !updatingLoginItem
    }

    @objc private func toggleLaunchAtLogin() {
        guard !updatingLoginItem else { return }
        let status = SMAppService.mainApp.status
        updatingLoginItem = true
        updateLoginItem()
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.updatingLoginItem = false
                self.updateLoginItem()
            }
            do {
                switch status {
                case .enabled, .requiresApproval:
                    try await SMAppService.mainApp.unregister()
                case .notRegistered, .notFound:
                    try SMAppService.mainApp.register()
                @unknown default:
                    return
                }
            } catch {
                let alert = NSAlert()
                alert.messageText = "无法更新开机自动启动"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.addButton(withTitle: "好")
                NSApp.activate()
                alert.runModal()
            }
        }
    }

    @objc private func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    @objc private func togglePaused() { controller.togglePaused() }
    @objc private func toggleMuted() { controller.toggleMuted() }
    @objc private func changeFillMode(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String, let mode = VideoFillMode(rawValue: rawValue) else { return }
        controller.setFillMode(mode)
    }
    @objc private func refresh() { controller.refresh(force: true) }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}
