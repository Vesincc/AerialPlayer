import AppKit
import AVFoundation
import CoreMedia
import QuartzCore

@MainActor
final class CrossfadeVideoPlayer {
    private enum Phase { case idle, preparing, playing, waitingForFrame, transitioning }

    private let window: DesktopWallpaperWindow
    private let fadeDuration = 1.0
    private var asset: AVURLAsset?
    private var players: [AVPlayer] = []
    private var layers: [AVPlayerLayer] = []
    private var observations: [NSKeyValueObservation] = []
    private var itemObservations: [Int: NSKeyValueObservation] = [:]
    private var endObservers: [Int: NSObjectProtocol] = [:]
    private var boundaryObserver: Any?
    private var boundaryPlayer: AVPlayer?
    private var boundaryGeneration = 0
    private var duration = 0.0
    private var playbackRate: Float = 1
    private var muted = true
    private var fillMode: VideoFillMode = .aspectFill
    private var fadeGeneration = 0
    private var fadeEndsAt = 0.0
    private var remainingFadeDuration = 1.0
    private var phase = Phase.idle
    private var activeIndex = 0
    private var generation = 0
    private var paused = false
    private var standbyPrepared = false
    private var warming = false
    private var prerollGeneration = 0
    private var warmRequested = false
    private var transitionRequested = false
    private var shown = false
    var onFailure: ((String) -> Void)?
    var onFirstFrame: (() -> Void)?

    init(window: DesktopWallpaperWindow) {
        self.window = window
    }

    func load(url: URL) async throws {
        if phase != .idle { stop() }
        let token = generation
        phase = .preparing
        let asset = AVURLAsset(url: url)
        let time = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard !tracks.isEmpty else { throw PlaybackError.noVideo }
        try Task.checkCancellation()
        guard generation == token else { return }
        duration = time.seconds
        guard duration.isFinite, duration > 0 else { throw PlaybackError.invalidDuration }
        guard duration / Double(playbackRate) > fadeDuration * 3 else { throw PlaybackError.tooShort }
        self.asset = asset

        for index in 0..<2 {
            let player = AVPlayer()
            player.isMuted = muted || index != activeIndex
            player.actionAtItemEnd = .pause
            player.defaultRate = playbackRate
            let layer = AVPlayerLayer()
            layer.videoGravity = fillMode.gravity
            layer.frame = window.videoSurface.bounds
            layer.opacity = index == 0 ? 1 : 0
            window.videoSurface.addSublayer(layer)
            players.append(player)
            layers.append(layer)
            observations.append(player.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.itemStatusChanged(index: index, token: token) }
            })
            observations.append(layer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.frameReady(index: index, token: token) }
            })
            observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.frameReady(index: index, token: token) }
            })
        }
        prepareItem(index: activeIndex)
    }

    private func prepareItem(index: Int) {
        guard let asset, players[index].currentItem == nil else { return }
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = Double(playbackRate) * 3
        let token = generation
        itemObservations[index] = item.observe(\.status, options: [.initial, .new]) { [weak self, weak item] _, _ in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.generation == token,
                      self.players.indices.contains(index), self.players[index].currentItem === item else { return }
                self.itemStatusChanged(index: index, token: token)
            }
        }
        endObservers[index] = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self, weak item] _ in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.generation == token,
                      self.players.indices.contains(index), self.players[index].currentItem === item else { return }
                self.reachedEnd(index: index, token: token)
            }
        }
        layers[index].player = players[index]
        players[index].replaceCurrentItem(with: item)
    }

    private func releaseItem(index: Int) {
        itemObservations.removeValue(forKey: index)?.invalidate()
        if let observer = endObservers.removeValue(forKey: index) {
            NotificationCenter.default.removeObserver(observer)
        }
        let player = players[index]
        player.pause()
        player.cancelPendingPrerolls()
        player.currentItem?.cancelPendingSeeks()
        layers[index].player = nil
        player.replaceCurrentItem(with: nil)
    }

    func setPlaybackRate(_ value: Float) {
        guard value.isFinite, value > 0, playbackRate != value else { return }
        playbackRate = value
        prerollGeneration += 1
        warming = false
        standbyPrepared = false
        players.forEach {
            $0.cancelPendingPrerolls()
            $0.defaultRate = value
            $0.currentItem?.preferredForwardBufferDuration = Double(value) * 3
        }
        if phase == .playing {
            let time = players[activeIndex].currentTime().seconds
            warmRequested = time >= duration - 3 * Double(value)
            transitionRequested = time >= duration - fadeDuration * Double(value)
            if !warmRequested { releaseItem(index: 1 - activeIndex) }
            installBoundaryObserver()
        }
        setPaused(paused)
    }

    func setMuted(_ value: Bool) {
        muted = value
        updateAudio()
    }

    func setFillMode(_ value: VideoFillMode) {
        guard fillMode != value else { return }
        fillMode = value
        CATransaction.begin()
        CATransaction.setDisableActions(!shown)
        CATransaction.setAnimationDuration(0.35)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        layers.forEach { $0.videoGravity = value.gravity }
        CATransaction.commit()
    }

    private func updateAudio() {
        // Only the active player contributes audio during the visual crossfade.
        for (index, player) in players.enumerated() {
            player.isMuted = muted || index != activeIndex
        }
    }

    func setPaused(_ value: Bool) {
        let wasPaused = paused
        paused = value
        if value {
            if !wasPaused, phase == .transitioning {
                let incoming = layers[1 - activeIndex]
                let opacity = incoming.presentation()?.opacity ?? incoming.opacity
                remainingFadeDuration = max(0, fadeEndsAt - CACurrentMediaTime())
                fadeGeneration += 1
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                incoming.opacity = opacity
                incoming.removeAnimation(forKey: "loopCrossfade")
                CATransaction.commit()
            }
            prerollGeneration += 1
            warming = false
            players.forEach { $0.pause(); $0.cancelPendingPrerolls() }
            if phase == .playing {
                standbyPrepared = false
                releaseItem(index: 1 - activeIndex)
            }
        } else {
            if shown { window.orderFrontRegardless() }
            switch phase {
            case .preparing:
                itemStatusChanged(index: activeIndex, token: generation)
            case .playing:
                players[activeIndex].play()
                if transitionRequested { attemptTransition() }
                else if warmRequested { warmStandby() }
            case .waitingForFrame, .transitioning:
                players.forEach { $0.play() }
                if phase == .waitingForFrame { frameReady(index: 1 - activeIndex, token: generation) }
                else if wasPaused { animateTransition(index: 1 - activeIndex, duration: remainingFadeDuration) }
            case .idle:
                break
            }
        }
    }

    func stop() {
        generation += 1
        fadeGeneration += 1
        prerollGeneration += 1
        removeBoundaryObserver()
        observations.removeAll()
        for index in players.indices { releaseItem(index: index) }
        asset = nil
        layers.forEach { $0.removeAllAnimations(); $0.player = nil; $0.removeFromSuperlayer() }
        players.removeAll()
        layers.removeAll()
        window.orderOut(nil)
        activeIndex = 0
        phase = .idle
        standbyPrepared = false
        warming = false
        warmRequested = false
        transitionRequested = false
        shown = false
    }

    private func itemStatusChanged(index: Int, token: Int) {
        guard generation == token, players.indices.contains(index), players[index].currentItem != nil else { return }
        if players[index].status == .failed || players[index].currentItem?.status == .failed {
            fail(players[index].error?.localizedDescription ?? players[index].currentItem?.error?.localizedDescription ?? "视频播放失败")
            return
        }
        guard players[index].status == .readyToPlay, players[index].currentItem?.status == .readyToPlay else { return }
        if phase == .preparing, index == activeIndex, !paused {
            phase = .playing
            installBoundaryObserver()
            players[index].play()
        } else if index != activeIndex, warmRequested {
            warmStandby()
        }
    }

    private func installBoundaryObserver() {
        removeBoundaryObserver()
        let player = players[activeIndex]
        let rate = Double(playbackRate)
        let times = [duration - 3 * rate, duration - fadeDuration * rate]
            .map { NSValue(time: CMTime(seconds: $0, preferredTimescale: 60000)) }
        let token = generation
        let boundaryToken = boundaryGeneration
        let index = activeIndex
        boundaryPlayer = player
        boundaryObserver = player.addBoundaryTimeObserver(forTimes: times, queue: .main) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, self.boundaryGeneration == boundaryToken,
                      self.activeIndex == index else { return }
                self.warmRequested = true
                if player.currentTime().seconds >= self.duration - self.fadeDuration * rate - 0.001 {
                    self.transitionRequested = true
                    self.attemptTransition()
                } else {
                    self.warmStandby()
                }
            }
        }
    }

    private func removeBoundaryObserver() {
        boundaryGeneration += 1
        if let boundaryObserver { boundaryPlayer?.removeTimeObserver(boundaryObserver) }
        boundaryObserver = nil
        boundaryPlayer = nil
    }

    private func warmStandby() {
        guard phase == .playing, !paused, !warming, !standbyPrepared else { return }
        let index = 1 - activeIndex
        let player = players[index]
        if player.currentItem == nil {
            prepareItem(index: index)
            return
        }
        guard player.status == .readyToPlay, player.currentItem?.status == .readyToPlay else { return }
        warming = true
        prerollGeneration += 1
        let prerollToken = prerollGeneration
        let token = generation
        player.preroll(atRate: playbackRate) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, self.prerollGeneration == prerollToken else { return }
                self.warming = false
                self.standbyPrepared = finished
                if finished, self.transitionRequested { self.attemptTransition() }
                else if !finished, !self.paused { self.fail("无法预加载下一轮视频") }
            }
        }
    }

    private func attemptTransition() {
        guard phase == .playing, transitionRequested, !paused else { return }
        guard standbyPrepared else { warmStandby(); return }
        phase = .waitingForFrame
        players[1 - activeIndex].play()
        frameReady(index: 1 - activeIndex, token: generation)
    }

    private func frameReady(index: Int, token: Int) {
        guard generation == token, layers.indices.contains(index), !paused, layers[index].isReadyForDisplay else { return }
        if index == activeIndex, !shown {
            shown = true
            window.orderFrontRegardless()
            onFirstFrame?()
        }
        guard phase == .waitingForFrame, index != activeIndex,
              players[index].timeControlStatus == .playing else { return }
        phase = .transitioning
        removeBoundaryObserver()
        let incomingLayer = layers[index]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        incomingLayer.removeFromSuperlayer()
        window.videoSurface.addSublayer(incomingLayer)
        incomingLayer.opacity = 0
        CATransaction.commit()

        animateTransition(index: index, duration: fadeDuration)
    }

    private func animateTransition(index: Int, duration: Double) {
        guard duration > 0 else { completeTransition(index: index, token: generation); return }
        let incomingLayer = layers[index]
        fadeGeneration += 1
        let fadeToken = fadeGeneration
        let token = generation
        fadeEndsAt = CACurrentMediaTime() + duration
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = incomingLayer.presentation()?.opacity ?? incomingLayer.opacity
        animation.toValue = 1
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.fadeGeneration == fadeToken, !self.paused else { return }
                self.completeTransition(index: index, token: token)
            }
        }
        // Keep the lower image opaque; fading both layers would expose the background halfway through.
        CATransaction.setDisableActions(true)
        incomingLayer.opacity = 1
        incomingLayer.add(animation, forKey: "loopCrossfade")
        CATransaction.commit()
    }

    private func completeTransition(index: Int, token: Int) {
        guard generation == token, phase == .transitioning else { return }
        let outgoing = activeIndex
        players[outgoing].pause()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layers[outgoing].opacity = 0
        CATransaction.commit()
        activeIndex = index
        updateAudio()
        phase = .playing
        warmRequested = false
        transitionRequested = false
        standbyPrepared = false
        // Release the decoder and buffered frames until the next loop needs them.
        releaseItem(index: outgoing)
        installBoundaryObserver()
    }

    private func reachedEnd(index: Int, token: Int) {
        guard generation == token, phase == .playing, index == activeIndex else { return }
        transitionRequested = true
        warmRequested = true
        attemptTransition()
    }

    private func fail(_ message: String) {
        stop()
        onFailure?(message)
    }

    private enum PlaybackError: LocalizedError {
        case noVideo, invalidDuration, tooShort

        var errorDescription: String? {
            switch self {
            case .noVideo: return "文件中没有视频轨道"
            case .invalidDuration: return "无法读取视频时长"
            case .tooShort: return "视频过短，无法进行 1 秒交叉淡化"
            }
        }
    }
}
