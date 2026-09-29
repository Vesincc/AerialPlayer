import AppKit
import AVFoundation
import QuartzCore
import CoreGraphics

@MainActor
final class DesktopWallpaperWindow: NSWindow {
    let videoSurface = CALayer()

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        // Stay above the system wallpaper provider and below Finder's desktop icons.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        hasShadow = false
        isOpaque = true
        backgroundColor = .black
        isReleasedWhenClosed = false
        canHide = false
        animationBehavior = .none

        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer = videoSurface
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func update(screen: NSScreen) {
        let surfaceFrame = NSRect(origin: .zero, size: screen.frame.size)
        guard frame != screen.frame || videoSurface.frame != surfaceFrame else { return }
        setFrame(screen.frame, display: true)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoSurface.frame = surfaceFrame
        videoSurface.sublayers?.forEach { $0.frame = videoSurface.bounds }
        CATransaction.commit()
    }

}
