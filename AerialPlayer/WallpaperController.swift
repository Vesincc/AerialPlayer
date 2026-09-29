import AppKit
import CoreGraphics
import QuartzCore
import Foundation
import Darwin

@MainActor
final class WallpaperController {
    static let playbackRateRange: ClosedRange<Float> = 0.25...2

    private final class Session {
        let wallpaper: ResolvedWallpaper
        let window: DesktopWallpaperWindow
        let player: CrossfadeVideoPlayer
        var loadTask: Task<Void, Never>?
        var previous: Session?
        var presented = false
        var retiring = false

        init(wallpaper: ResolvedWallpaper, screen: NSScreen) {
            self.wallpaper = wallpaper
            window = DesktopWallpaperWindow(screen: screen)
            window.update(screen: screen)
            player = CrossfadeVideoPlayer(window: window)
        }

        func stop() {
            loadTask?.cancel()
            loadTask = nil
            player.onFirstFrame = nil
            player.onFailure = nil
            player.stop()
            window.close()
            presented = false
            previous?.stop()
            previous = nil
        }
    }

    private enum Suspension: Hashable { case locked, displaySleep, systemSleep, inactiveSession, thermal }
    private let resolver = CurrentWallpaperResolver()
    private var sessions: [String: Session] = [:]
    private var screenNames: [String: String] = [:]
    private var errors: [String: String] = [:]
    private var suspensions: Set<Suspension> = []
    private var notifications: [(NotificationCenter, NSObjectProtocol)] = []
    private var directoryWatchers: [DispatchSourceFileSystemObject] = []
    private var refreshTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var stopped = false
    private(set) var userPaused = false
    private(set) var playbackRate: Float
    private(set) var isMuted: Bool
    private(set) var fillMode: VideoFillMode
    private(set) var statusMessage = "正在读取当前壁纸…"
    var onChange: (() -> Void)?

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: ["playbackRate": 1.0, "isMuted": true, "fillMode": VideoFillMode.aspectFill.rawValue])
        let rate = defaults.float(forKey: "playbackRate")
        playbackRate = Self.playbackRateRange.contains(rate) ? rate : 1
        isMuted = defaults.bool(forKey: "isMuted")
        fillMode = defaults.string(forKey: "fillMode").flatMap(VideoFillMode.init(rawValue:)) ?? .aspectFill
    }

    var hasVideo: Bool { sessions.contains { !$0.value.retiring && ($0.value.presented || errors[$0.key] == nil) } }

    var wallpaperDescriptions: [String] {
        screenNames.keys.sorted().map { id in
            let description = errors[id] ?? sessions[id]?.wallpaper.name ?? "正在读取…"
            return "\(screenNames[id] ?? "显示器")：\(description)"
        }
    }

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.setSuspension(.displaySleep, enabled: true) }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.setSuspension(.displaySleep, enabled: false) }
        observe(workspace, NSWorkspace.willSleepNotification) { $0.setSuspension(.systemSleep, enabled: true) }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.setSuspension(.systemSleep, enabled: false); $0.refresh() }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.setSuspension(.inactiveSession, enabled: true) }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.setSuspension(.inactiveSession, enabled: false); $0.refresh() }
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { $0.scheduleRefresh() }
        observe(.default, NSApplication.didChangeScreenParametersNotification) { $0.scheduleRefresh() }
        observe(.default, ProcessInfo.thermalStateDidChangeNotification) { $0.updateThermalState() }
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked")) {
            $0.setSuspension(.locked, enabled: true)
        }
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked")) {
            $0.setSuspension(.locked, enabled: false)
            $0.refresh()
        }
        updateThermalState()
        watchDirectory(resolver.storeDirectory)
        watchDirectory(resolver.aerialsDirectory.appendingPathComponent("videos", isDirectory: true))
        refresh()
    }

    func togglePaused() {
        userPaused.toggle()
        updatePlayback()
    }

    func setPlaybackRate(_ rate: Float) {
        guard Self.playbackRateRange.contains(rate), playbackRate != rate else { return }
        playbackRate = rate
        UserDefaults.standard.set(rate, forKey: "playbackRate")
        for session in sessions.values {
            session.player.setPlaybackRate(rate)
            session.previous?.player.setPlaybackRate(rate)
        }
        updateStatus()
    }

    func toggleMuted() {
        isMuted.toggle()
        UserDefaults.standard.set(isMuted, forKey: "isMuted")
        for session in sessions.values {
            session.player.setMuted(isMuted)
            session.previous?.player.setMuted(isMuted)
        }
        updateStatus()
    }

    func setFillMode(_ mode: VideoFillMode) {
        guard fillMode != mode else { return }
        fillMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "fillMode")
        for session in sessions.values {
            session.player.setFillMode(mode)
            session.previous?.player.setFillMode(mode)
        }
        updateStatus()
    }

    func refresh(force: Bool = false) {
        guard !stopped else { return }
        debounceTask?.cancel()
        refreshTask?.cancel()
        refreshGeneration += 1
        let generation = refreshGeneration
        let screens = Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen -> (String, NSScreen)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
            return (CFUUIDCreateString(nil, uuid) as String, screen)
        })
        screenNames = screens.mapValues(\.localizedName)
        errors = errors.filter { screens[$0.key] != nil }
        for id in Array(sessions.keys) where screens[id] == nil {
            sessions.removeValue(forKey: id)?.stop()
            errors.removeValue(forKey: id)
        }
        let displayIDs = Array(screens.keys)
        let resolver = resolver
        refreshTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Result { try resolver.resolve(displayIDs: displayIDs) }
            }.value
            guard let self, !Task.isCancelled, self.refreshGeneration == generation else { return }
            switch result {
            case .success(let wallpapers):
                for (id, screen) in screens {
                    guard let selection = wallpapers[id] else { continue }
                    switch selection {
                    case .success(let wallpaper):
                        if !force, let session = self.sessions[id], session.wallpaper == wallpaper, self.errors[id] == nil {
                            session.window.update(screen: screen)
                            session.previous?.window.update(screen: screen)
                            continue
                        }
                        self.errors.removeValue(forKey: id)
                        self.createSession(wallpaper: wallpaper, screen: screen, id: id)
                    case .failure(let error):
                        if error == .notAerial { self.fadeOutSession(id: id) }
                        else { self.sessions.removeValue(forKey: id)?.stop() }
                        self.errors[id] = error.localizedDescription
                    }
                }
            case .failure(let error):
                self.sessions.values.forEach { $0.stop() }
                self.sessions.removeAll()
                self.errors = Dictionary(uniqueKeysWithValues: displayIDs.map { ($0, "无法读取壁纸配置：\(error.localizedDescription)") })
            }
            self.refreshTask = nil
            self.updateStatus()
        }
    }

    func stop() {
        stopped = true
        refreshGeneration += 1
        refreshTask?.cancel()
        debounceTask?.cancel()
        sessions.values.forEach { $0.stop() }
        sessions.removeAll()
        directoryWatchers.forEach { $0.cancel() }
        directoryWatchers.removeAll()
        notifications.forEach { $0.0.removeObserver($0.1) }
        notifications.removeAll()
        onChange = nil
    }

    private func createSession(wallpaper: ResolvedWallpaper, screen: NSScreen, id: String) {
        let previous = retainPresentedSession(sessions[id])
        previous?.window.update(screen: screen)
        let session = Session(wallpaper: wallpaper, screen: screen)
        session.previous = previous
        if previous != nil { session.window.alphaValue = 0 }
        sessions[id] = session
        session.player.setPlaybackRate(playbackRate)
        session.player.setMuted(isMuted)
        session.player.setFillMode(fillMode)
        session.player.setPaused(userPaused || !suspensions.isEmpty)
        session.player.onFirstFrame = { [weak self, weak session] in
            guard let self, let session, self.sessions[id] === session else { return }
            session.presented = true
            guard let previous = session.previous else { self.updateStatus(); return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 1
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                session.window.animator().alphaValue = 1
            } completionHandler: { [weak self, weak session, weak previous] in
                Task { @MainActor [weak self, weak session, weak previous] in
                    guard let self, let session, let previous,
                          self.sessions[id] === session, session.previous === previous else { return }
                    session.previous = nil
                    previous.stop()
                }
            }
            self.updateStatus()
        }
        session.player.onFailure = { [weak self, weak session] message in
            guard let self, let session, self.sessions[id] === session else { return }
            self.sessionFailed(session, id: id, message: message)
        }
        session.loadTask = Task { [weak self, weak session] in
            guard let self, let session else { return }
            do {
                try await session.player.load(url: wallpaper.videoURL)
            } catch is CancellationError {
                return
            } catch {
                guard self.sessions[id] === session else { return }
                self.sessionFailed(session, id: id, message: error.localizedDescription)
                return
            }
            guard self.sessions[id] === session else { return }
            session.loadTask = nil
            self.updateStatus()
        }
    }

    private func retainPresentedSession(_ session: Session?) -> Session? {
        guard let session else { return nil }
        let previous = session.previous
        session.previous = nil
        if !session.presented {
            session.stop()
            return previous
        }
        // Bound rapid replacements to one visible session and one incoming session.
        session.window.alphaValue = 1
        session.retiring = false
        previous?.stop()
        session.player.setPaused(true)
        return session
    }

    private func sessionFailed(_ session: Session, id: String, message: String) {
        let previous = session.previous
        session.previous = nil
        session.stop()
        sessions[id] = previous
        previous?.player.setPaused(userPaused || !suspensions.isEmpty)
        if !suspensions.isEmpty { previous?.window.orderOut(nil) }
        errors[id] = message
        updateStatus()
    }

    private func fadeOutSession(id: String) {
        guard sessions[id]?.retiring != true else { return }
        let session = retainPresentedSession(sessions[id])
        sessions[id] = session
        guard let session else { return }
        session.retiring = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 1
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            session.window.animator().alphaValue = 0
        } completionHandler: { [weak self, weak session] in
            Task { @MainActor [weak self, weak session] in
                guard let self, let session, self.sessions[id] === session, session.retiring else { return }
                self.sessions.removeValue(forKey: id)?.stop()
                self.updateStatus()
            }
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, action: @escaping @MainActor (WallpaperController) -> Void) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                action(self)
            }
        }
        notifications.append((center, observer))
    }

    private func watchDirectory(_ directory: URL) {
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in self?.scheduleRefresh() }
        }
        source.setCancelHandler { close(descriptor) }
        directoryWatchers.append(source)
        source.resume()
    }

    private func scheduleRefresh() {
        guard !stopped else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) }
            catch { return }
            self?.refresh()
        }
    }

    private func setSuspension(_ reason: Suspension, enabled: Bool) {
        guard suspensions.contains(reason) != enabled else { return }
        if enabled { suspensions.insert(reason) }
        else { suspensions.remove(reason) }
        updatePlayback()
    }

    private func updateThermalState() {
        let thermal = ProcessInfo.processInfo.thermalState
        setSuspension(.thermal, enabled: thermal == .serious || thermal == .critical)
    }

    private func updatePlayback() {
        let paused = userPaused || !suspensions.isEmpty
        for session in sessions.values {
            if session.retiring {
                if suspensions.isEmpty { session.window.orderFrontRegardless() }
                else { session.window.orderOut(nil) }
                continue
            }
            if let previous = session.previous {
                if suspensions.isEmpty { previous.window.orderFrontRegardless() }
                else { previous.window.orderOut(nil) }
            }
            session.player.setPaused(paused)
            if !suspensions.isEmpty { session.window.orderOut(nil) }
        }
        updateStatus()
    }

    private func updateStatus() {
        if sessions.isEmpty || sessions.values.allSatisfy({ $0.retiring }) { statusMessage = errors.values.sorted().first ?? "未找到可播放的航拍壁纸" }
        else if errors.count == screenNames.count { statusMessage = "播放失败，可重新读取壁纸" }
        else if userPaused { statusMessage = "已暂停" }
        else if !suspensions.isEmpty { statusMessage = "系统暂停，恢复后继续播放" }
        else if sessions.values.contains(where: { $0.loadTask != nil || !$0.presented }) { statusMessage = "正在准备视频…" }
        else { statusMessage = errors.isEmpty ? "正在播放 · 1 秒交叉淡化" : "部分显示器无法播放" }
        onChange?()
    }
}
