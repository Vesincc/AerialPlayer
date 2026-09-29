import AppKit
import ServiceManagement

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private final class SpeedSlider: NSSlider {
        private(set) var isTrackingMouse = false

        override func mouseDown(with event: NSEvent) {
            isTrackingMouse = true
            defer { isTrackingMouse = false }
            super.mouseDown(with: event)
        }
    }

    private let controller: WallpaperController
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var loginItem: NSMenuItem?
    private var loginApprovalItem: NSMenuItem?
    private var updatingLoginItem = false
    private var speedSlider: SpeedSlider?
    private var speedLabel: NSTextField?
    private var muteItem: NSMenuItem?
    private var fillItems: [VideoFillMode: NSMenuItem] = [:]
    private var menuIsOpen = false
    private var menuNeedsUpdate = false

    init(controller: WallpaperController) {
        self.controller = controller
        super.init()
        controller.onChange = { [weak self] in self?.updateMenu() }
        updateMenu()
    }

    func remove() {
        NSStatusBar.system.removeStatusItem(item)
    }

    private func updateMenu() {
        if menuIsOpen {
            menuNeedsUpdate = true
            updatePlaybackControls()
            return
        }
        let descriptions = controller.wallpaperDescriptions
        let symbol = controller.userPaused ? "pause.rectangle" : "play.rectangle"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "AerialPlayer")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "AerialPlayer · \(controller.statusMessage)"

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        let status = NSMenuItem(title: controller.statusMessage, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        for description in descriptions {
            let wallpaper = NSMenuItem(title: description, action: nil, keyEquivalent: "")
            wallpaper.isEnabled = false
            menu.addItem(wallpaper)
        }
        menu.addItem(.separator())
        let pause = NSMenuItem(title: controller.userPaused ? "继续播放" : "暂停播放", action: #selector(togglePaused), keyEquivalent: "")
        pause.target = self
        pause.isEnabled = controller.hasVideo
        menu.addItem(pause)
        let speed = NSMenuItem()
        speed.view = makeSpeedControl()
        menu.addItem(speed)
        let mute = NSMenuItem(title: "静音", action: #selector(toggleMuted), keyEquivalent: "")
        mute.target = self
        mute.state = controller.isMuted ? .on : .off
        menu.addItem(mute)
        muteItem = mute
        let fill = NSMenuItem(title: "填充模式", action: nil, keyEquivalent: "")
        let modes = NSMenu()
        modes.autoenablesItems = false
        fillItems.removeAll()
        for mode in VideoFillMode.allCases {
            let option = NSMenuItem(title: mode.title, action: #selector(changeFillMode(_:)), keyEquivalent: "")
            option.target = self
            option.representedObject = mode.rawValue
            option.state = mode == controller.fillMode ? .on : .off
            modes.addItem(option)
            fillItems[mode] = option
        }
        fill.submenu = modes
        menu.addItem(fill)
        let refresh = NSMenuItem(title: "重新读取当前壁纸", action: #selector(refresh), keyEquivalent: "")
        refresh.target = self
        menu.addItem(refresh)
        menu.addItem(.separator())
        let login = NSMenuItem(title: "开机自动启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        menu.addItem(login)
        loginItem = login
        let approval = NSMenuItem(title: "在系统设置中允许自动启动…", action: #selector(openLoginItemsSettings), keyEquivalent: "")
        approval.target = self
        menu.addItem(approval)
        loginApprovalItem = approval
        updateLoginItem()
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 AerialPlayer", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
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

    private func makeSpeedControl() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 64))
        view.autoresizingMask = [.width]
        let title = NSTextField(labelWithString: "播放速度")
        title.font = .menuFont(ofSize: 0)
        title.frame = NSRect(x: 30, y: 40, width: 90, height: 18)
        view.addSubview(title)
        let value = NSTextField(labelWithString: String(format: "%.2f×", Double(controller.playbackRate)))
        value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        value.alignment = .right
        value.frame = NSRect(x: 162, y: 40, width: 54, height: 18)
        value.autoresizingMask = [.minXMargin]
        view.addSubview(value)
        speedLabel = value
        let slider = SpeedSlider(value: Double(controller.playbackRate),
                              minValue: Double(WallpaperController.playbackRateRange.lowerBound),
                              maxValue: Double(WallpaperController.playbackRateRange.upperBound),
                              target: self, action: #selector(changePlaybackRate(_:)))
        slider.controlSize = .small
        slider.frame = NSRect(x: 30, y: 10, width: 234, height: 20)
        slider.autoresizingMask = [.width]
        slider.isContinuous = true
        slider.setAccessibilityLabel("播放速度")
        view.addSubview(slider)
        speedSlider = slider
        let reset = NSButton(title: "1×", target: self, action: #selector(resetPlaybackRate))
        reset.bezelStyle = .rounded
        reset.controlSize = .small
        reset.frame = NSRect(x: 224, y: 36, width: 40, height: 24)
        reset.autoresizingMask = [.minXMargin]
        reset.toolTip = "恢复正常播放速度"
        view.addSubview(reset)
        return view
    }

    private func updatePlaybackControls() {
        // AppKit owns the knob position throughout native mouse tracking.
        if let slider = speedSlider, !slider.isTrackingMouse {
            let value = Double(controller.playbackRate)
            if slider.doubleValue != value { slider.doubleValue = value }
        }
        speedLabel?.stringValue = String(format: "%.2f×", Double(controller.playbackRate))
        muteItem?.state = controller.isMuted ? .on : .off
        for (mode, option) in fillItems {
            option.state = mode == controller.fillMode ? .on : .off
        }
    }

    private func updateLoginItem() {
        let status = SMAppService.mainApp.status
        loginItem?.title = status == .requiresApproval ? "开机自动启动（待系统允许）" : "开机自动启动"
        loginItem?.isEnabled = !updatingLoginItem
        switch status {
        case .enabled: loginItem?.state = .on
        case .requiresApproval: loginItem?.state = .mixed
        case .notRegistered, .notFound: loginItem?.state = .off
        @unknown default:
            loginItem?.state = .off
            loginItem?.isEnabled = false
        }
        loginApprovalItem?.isHidden = status != .requiresApproval
        loginApprovalItem?.isEnabled = !updatingLoginItem
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
    @objc private func changePlaybackRate(_ sender: NSSlider) {
        controller.setPlaybackRate(Float((sender.doubleValue * 100).rounded() / 100))
        updatePlaybackControls()
    }
    @objc private func resetPlaybackRate() {
        controller.setPlaybackRate(1)
        menuNeedsUpdate = true
        updatePlaybackControls()
    }
    @objc private func toggleMuted() { controller.toggleMuted() }
    @objc private func changeFillMode(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String, let mode = VideoFillMode(rawValue: rawValue) else { return }
        controller.setFillMode(mode)
    }
    @objc private func refresh() { controller.refresh(force: true) }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}
