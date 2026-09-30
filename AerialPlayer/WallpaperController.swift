import AppKit
import CoreGraphics

@MainActor
final class WallpaperController {
    static let playbackRateRange: ClosedRange<Float> = 0.25...2

    private let resolver = CurrentWallpaperResolver()
    private let eventMonitor = WallpaperEventMonitor()
    private let stillWallpapers = StillWallpaperStore()
    private var sessions: [String: WallpaperSession] = [:]
    private var screenNames: [String: String] = [:]
    private var errors: [String: String] = [:]
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var stopped = false
    private(set) var userPaused = false
    private(set) var playbackRate: Float
    private(set) var isMuted: Bool
    private(set) var fillMode: VideoFillMode
    private(set) var statusMessage = "正在读取当前壁纸…"
    var onChange: (() -> Void)?

    private var isPaused: Bool { userPaused || eventMonitor.isSuspended }

    var hasVideo: Bool {
        sessions.contains { !$0.value.isRetiring && ($0.value.isPresented || errors[$0.key] == nil) }
    }

    var wallpaperDescriptions: [String] {
        screenNames.keys.sorted().map { id in
            let description = errors[id] ?? sessions[id]?.wallpaper.name ?? "正在读取…"
            return "\(screenNames[id] ?? "显示器")：\(description)"
        }
    }

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: ["playbackRate": 1.0, "isMuted": true, "fillMode": VideoFillMode.aspectFill.rawValue])
        let rate = defaults.float(forKey: "playbackRate")
        playbackRate = Self.playbackRateRange.contains(rate) ? rate : 1
        isMuted = defaults.bool(forKey: "isMuted")
        fillMode = defaults.string(forKey: "fillMode").flatMap(VideoFillMode.init(rawValue:)) ?? .aspectFill
    }

    func start() {
        eventMonitor.onRefresh = { [weak self] in self?.refresh() }
        eventMonitor.onSuspensionChange = { [weak self] in self?.updatePlayback() }
        eventMonitor.start(directories: [
            resolver.storeDirectory,
            resolver.aerialsDirectory.appendingPathComponent("videos", isDirectory: true)
        ])
        refresh()
    }

    func stop() {
        stopped = true
        refreshGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
        eventMonitor.stop()
        stopSessions()
        stillWallpapers.removeAll()
        onChange = nil
    }

    func togglePaused() {
        userPaused.toggle()
        updatePlayback()
    }

    func setPlaybackRate(_ rate: Float) {
        guard Self.playbackRateRange.contains(rate), playbackRate != rate else { return }
        playbackRate = rate
        UserDefaults.standard.set(rate, forKey: "playbackRate")
        sessions.values.forEach { $0.setPlaybackRate(rate) }
        updateStatus()
    }

    func toggleMuted() {
        isMuted.toggle()
        UserDefaults.standard.set(isMuted, forKey: "isMuted")
        sessions.values.forEach { $0.setMuted(isMuted) }
        updateStatus()
    }

    func setFillMode(_ mode: VideoFillMode) {
        guard fillMode != mode else { return }
        fillMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "fillMode")
        sessions.values.forEach { $0.setFillMode(mode) }
        updateStatus()
    }

    func refresh(force: Bool = false) {
        guard !stopped else { return }
        eventMonitor.cancelPendingRefresh()
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
        }
        let displayIDs = Array(screens.keys)
        stillWallpapers.removeDisconnected(keeping: Set(displayIDs))
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
                    self.applySelection(selection, screen: screen, id: id, force: force)
                }
            case .failure(let error):
                self.stopSessions()
                self.stillWallpapers.removeAll()
                self.errors = Dictionary(uniqueKeysWithValues: displayIDs.map {
                    ($0, "无法读取壁纸配置：\(error.localizedDescription)")
                })
            }
            self.refreshTask = nil
            self.updateStatus()
        }
    }

    private func applySelection(_ selection: Result<ResolvedWallpaper, CurrentWallpaperResolver.ResolutionError>,
                                screen: NSScreen, id: String, force: Bool) {
        switch selection {
        case .success(let wallpaper):
            if !force, let session = sessions[id], session.wallpaper == wallpaper, errors[id] == nil {
                session.update(screen: screen)
                return
            }
            errors.removeValue(forKey: id)
            createSession(wallpaper: wallpaper, screen: screen, id: id)
        case .failure(let error):
            if error == .notAerial {
                fadeOutSession(id: id)
                stillWallpapers.prepare(screen: screen, id: id, below: sessions[id]?.window)
            } else {
                stillWallpapers.remove(id: id)
                sessions.removeValue(forKey: id)?.stop()
            }
            errors[id] = error.localizedDescription
        }
    }

    private func createSession(wallpaper: ResolvedWallpaper, screen: NSScreen, id: String) {
        let stillWindow = stillWallpapers.takeWindow(id: id)
        let previous: WallpaperSession?
        if stillWindow != nil {
            sessions[id]?.stop()
            previous = nil
        } else {
            previous = sessions[id]?.retainForReplacement()
        }
        previous?.update(screen: screen)
        let session = WallpaperSession(wallpaper: wallpaper, screen: screen, window: stillWindow, previous: previous)
        sessions[id] = session
        session.setPlaybackRate(playbackRate)
        session.setMuted(isMuted)
        session.setFillMode(fillMode)
        session.updatePlayback(paused: isPaused, hidden: eventMonitor.isSuspended)
        session.onChange = { [weak self, weak session] in
            guard let self, let session, self.sessions[id] === session else { return }
            self.updateStatus()
        }
        session.onFailure = { [weak self, weak session] message in
            guard let self, let session, self.sessions[id] === session else { return }
            self.sessionFailed(session, id: id, message: message)
        }
        session.startLoading()
    }

    private func sessionFailed(_ session: WallpaperSession, id: String, message: String) {
        let previous = session.detachPrevious()
        session.stop()
        sessions[id] = previous
        previous?.updatePlayback(paused: isPaused, hidden: eventMonitor.isSuspended)
        errors[id] = message
        updateStatus()
    }

    private func fadeOutSession(id: String) {
        guard let current = sessions[id], !current.isRetiring else { return }
        let session = current.retainForReplacement()
        sessions[id] = session
        guard let session else { return }
        session.fadeOut { [weak self, weak session] in
            guard let self, let session, self.sessions[id] === session else { return }
            self.sessions.removeValue(forKey: id)?.stop()
            self.updateStatus()
        }
    }

    private func stopSessions() {
        sessions.values.forEach { $0.stop() }
        sessions.removeAll()
    }

    private func updatePlayback() {
        stillWallpapers.setHidden(eventMonitor.isSuspended)
        sessions.values.forEach { $0.updatePlayback(paused: isPaused, hidden: eventMonitor.isSuspended) }
        updateStatus()
    }

    private func updateStatus() {
        if sessions.isEmpty || sessions.values.allSatisfy({ $0.isRetiring }) {
            statusMessage = errors.values.sorted().first ?? "未找到可播放的航拍壁纸"
        } else if errors.count == screenNames.count {
            statusMessage = "播放失败，可重新读取壁纸"
        } else if userPaused {
            statusMessage = "已暂停"
        } else if eventMonitor.isSuspended {
            statusMessage = "系统暂停，恢复后继续播放"
        } else if sessions.values.contains(where: { $0.isPreparing }) {
            statusMessage = "正在准备视频…"
        } else {
            statusMessage = errors.isEmpty ? "正在播放 · 1 秒交叉淡化" : "部分显示器无法播放"
        }
        onChange?()
    }
}
