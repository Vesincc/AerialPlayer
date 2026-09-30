import AppKit
import Darwin

@MainActor
final class WallpaperEventMonitor {
    private enum Suspension: Hashable { case locked, displaySleep, systemSleep, inactiveSession, thermal }
    private var suspensions: Set<Suspension> = []
    private var notifications: [(NotificationCenter, NSObjectProtocol)] = []
    private var directoryWatchers: [DispatchSourceFileSystemObject] = []
    private var debounceTask: Task<Void, Never>?
    private var isRunning = false
    var onRefresh: (() -> Void)?
    var onSuspensionChange: (() -> Void)?

    var isSuspended: Bool { !suspensions.isEmpty }

    func start(directories: [URL]) {
        guard !isRunning else { return }
        isRunning = true
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.setSuspension(.displaySleep, enabled: true) }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.setSuspension(.displaySleep, enabled: false) }
        observe(workspace, NSWorkspace.willSleepNotification) { $0.setSuspension(.systemSleep, enabled: true) }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.setSuspension(.systemSleep, enabled: false); $0.onRefresh?() }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.setSuspension(.inactiveSession, enabled: true) }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.setSuspension(.inactiveSession, enabled: false); $0.onRefresh?() }
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { $0.scheduleRefresh() }
        observe(.default, NSApplication.didChangeScreenParametersNotification) { $0.scheduleRefresh() }
        observe(.default, ProcessInfo.thermalStateDidChangeNotification) { $0.updateThermalState() }
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked")) {
            $0.setSuspension(.locked, enabled: true)
        }
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked")) {
            $0.setSuspension(.locked, enabled: false)
            $0.onRefresh?()
        }
        updateThermalState()
        directories.forEach { watchDirectory($0) }
    }

    func stop() {
        isRunning = false
        cancelPendingRefresh()
        directoryWatchers.forEach { $0.cancel() }
        directoryWatchers.removeAll()
        notifications.forEach { $0.0.removeObserver($0.1) }
        notifications.removeAll()
        onRefresh = nil
        onSuspensionChange = nil
    }

    func cancelPendingRefresh() {
        debounceTask?.cancel()
        debounceTask = nil
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         action: @escaping @MainActor (WallpaperEventMonitor) -> Void) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
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
        guard isRunning else { return }
        cancelPendingRefresh()
        debounceTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) }
            catch { return }
            guard let self, self.isRunning else { return }
            self.debounceTask = nil
            self.onRefresh?()
        }
    }

    private func setSuspension(_ reason: Suspension, enabled: Bool) {
        guard suspensions.contains(reason) != enabled else { return }
        if enabled { suspensions.insert(reason) }
        else { suspensions.remove(reason) }
        onSuspensionChange?()
    }

    private func updateThermalState() {
        let thermal = ProcessInfo.processInfo.thermalState
        setSuspension(.thermal, enabled: thermal == .serious || thermal == .critical)
    }
}
