import AppKit
import CoreGraphics
import ImageIO
import QuartzCore

@MainActor
final class StillWallpaperStore {
    private final class Entry {
        let url: URL
        var window: DesktopWallpaperWindow?
        var loadTask: Task<Void, Never>?

        init(url: URL) { self.url = url }
    }

    private var entries: [String: Entry] = [:]
    private var isHidden = false

    func prepare(screen: NSScreen, id: String, below coveringWindow: DesktopWallpaperWindow?) {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen), url.isFileURL else {
            remove(id: id)
            return
        }
        if let entry = entries[id], entry.url == url {
            entry.window?.update(screen: screen)
            return
        }
        remove(id: id)
        let entry = Entry(url: url)
        entries[id] = entry
        let gravity = imageGravity(screen: screen)
        let maxPixels = Int(ceil(max(screen.frame.width, screen.frame.height) * screen.backingScaleFactor))
        entry.loadTask = Task { [weak self, weak entry, weak coveringWindow] in
            let image = await Task.detached(priority: .utility) {
                Self.loadImage(url: url, maxPixels: maxPixels)
            }.value
            guard let self, let entry, !Task.isCancelled, self.entries[id] === entry else { return }
            entry.loadTask = nil
            guard let image else {
                self.entries.removeValue(forKey: id)
                return
            }
            let window = DesktopWallpaperWindow(screen: screen)
            window.update(screen: screen)
            window.setTransitionImage(image, gravity: gravity)
            entry.window = window
            guard !self.isHidden else { return }
            if let coveringWindow, coveringWindow.isVisible {
                window.order(.below, relativeTo: coveringWindow.windowNumber)
            } else {
                window.alphaValue = 0
                window.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.35
                    window.animator().alphaValue = 1
                }, completionHandler: {})
            }
        }
    }

    func takeWindow(id: String) -> DesktopWallpaperWindow? {
        guard let entry = entries.removeValue(forKey: id) else { return nil }
        entry.loadTask?.cancel()
        return entry.window
    }

    func remove(id: String) {
        guard let window = takeWindow(id: id) else { return }
        window.clearTransitionImage()
        window.close()
    }

    func removeDisconnected(keeping displayIDs: Set<String>) {
        for id in Array(entries.keys) where !displayIDs.contains(id) { remove(id: id) }
    }

    func removeAll() {
        for id in Array(entries.keys) { remove(id: id) }
    }

    func setHidden(_ hidden: Bool) {
        guard isHidden != hidden else { return }
        isHidden = hidden
        for entry in entries.values {
            guard let window = entry.window else { continue }
            if hidden { window.orderOut(nil) }
            else { window.orderFrontRegardless() }
        }
    }

    private func imageGravity(screen: NSScreen) -> CALayerContentsGravity {
        let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
        let scaling = (options[.imageScaling] as? NSNumber).flatMap { NSImageScaling(rawValue: $0.uintValue) }
        switch scaling {
        case .scaleAxesIndependently: return .resize
        case .scaleNone: return .center
        default: return (options[.allowClipping] as? Bool) == false ? .resizeAspect : .resizeAspectFill
        }
    }

    nonisolated private static func loadImage(url: URL, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
