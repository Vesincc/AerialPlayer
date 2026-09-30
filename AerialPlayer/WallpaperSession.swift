import AppKit
import QuartzCore

@MainActor
final class WallpaperSession {
    let wallpaper: ResolvedWallpaper
    let window: DesktopWallpaperWindow
    private let player: CrossfadeVideoPlayer
    private var loadTask: Task<Void, Never>?
    private var presentationGeneration = 0
    private var previous: WallpaperSession?
    private(set) var isPresented = false
    private(set) var isRetiring = false
    var onChange: (() -> Void)?
    var onFailure: ((String) -> Void)?

    var isPreparing: Bool { loadTask != nil || !isPresented }

    init(wallpaper: ResolvedWallpaper, screen: NSScreen, window: DesktopWallpaperWindow? = nil,
         previous: WallpaperSession? = nil) {
        self.wallpaper = wallpaper
        self.window = window ?? DesktopWallpaperWindow(screen: screen)
        self.previous = previous
        self.window.update(screen: screen)
        if window == nil { self.window.alphaValue = 0 }
        player = CrossfadeVideoPlayer(window: self.window)
    }

    func startLoading() {
        player.onFirstFrame = { [weak self] in self?.present() }
        player.onFailure = { [weak self] message in self?.onFailure?(message) }
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.player.load(url: self.wallpaper.videoURL)
            } catch is CancellationError {
                return
            } catch {
                self.onFailure?(error.localizedDescription)
                return
            }
            guard !Task.isCancelled else { return }
            self.loadTask = nil
            self.onChange?()
        }
    }

    func update(screen: NSScreen) {
        window.update(screen: screen)
        previous?.window.update(screen: screen)
    }

    func setPlaybackRate(_ rate: Float) {
        player.setPlaybackRate(rate)
        previous?.player.setPlaybackRate(rate)
    }

    func setMuted(_ muted: Bool) {
        player.setMuted(muted)
        previous?.player.setMuted(muted)
    }

    func setFillMode(_ mode: VideoFillMode) {
        player.setFillMode(mode)
        previous?.player.setFillMode(mode)
    }

    func updatePlayback(paused: Bool, hidden: Bool) {
        if isRetiring {
            if hidden { window.orderOut(nil) }
            else { window.orderFrontRegardless() }
            return
        }
        if let previous {
            if hidden { previous.window.orderOut(nil) }
            else { previous.window.orderFrontRegardless() }
        }
        player.setPaused(paused)
        if hidden { window.orderOut(nil) }
    }

    func retainForReplacement() -> WallpaperSession? {
        presentationGeneration += 1
        let previous = detachPrevious()
        if !isPresented && window.transitionImageLayer == nil {
            stop()
            return previous
        }
        // Bound rapid replacements to one visible session and one incoming session.
        window.alphaValue = 1
        isRetiring = false
        previous?.stop()
        player.setPaused(true)
        return self
    }

    func detachPrevious() -> WallpaperSession? {
        let previous = self.previous
        self.previous = nil
        return previous
    }

    func fadeOut(completion: @escaping @MainActor () -> Void) {
        isRetiring = true
        presentationGeneration += 1
        let token = presentationGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 1
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.presentationGeneration == token, self.isRetiring else { return }
                completion()
            }
        }
    }

    func stop() {
        presentationGeneration += 1
        onChange = nil
        onFailure = nil
        loadTask?.cancel()
        loadTask = nil
        player.onFirstFrame = nil
        player.onFailure = nil
        player.stop()
        window.clearTransitionImage()
        window.close()
        isPresented = false
        detachPrevious()?.stop()
    }

    private func present() {
        isPresented = true
        presentationGeneration += 1
        let token = presentationGeneration
        let finish: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.presentationGeneration == token else { return }
                self.window.clearTransitionImage()
                self.detachPrevious()?.stop()
            }
        }
        if let layer = window.transitionImageLayer {
            window.alphaValue = 1
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = 1
            animation.toValue = 0
            animation.duration = 1
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            CATransaction.begin()
            CATransaction.setCompletionBlock(finish)
            CATransaction.setDisableActions(true)
            layer.opacity = 0
            layer.add(animation, forKey: "stillImageFade")
            CATransaction.commit()
        } else {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 1
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().alphaValue = 1
            }, completionHandler: finish)
        }
        onChange?()
    }
}
