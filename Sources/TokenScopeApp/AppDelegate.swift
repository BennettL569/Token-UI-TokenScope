import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    /// Windows we have already configured. Each window only needs its restoration
    /// state disabled once; tracking them lets us avoid redoing the work repeatedly.
    private var configuredWindows = Set<ObjectIdentifier>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        NSWindow.allowsAutomaticWindowTabbing = false
        // Configure each window exactly once — when it first appears / becomes key —
        // instead of on every `applicationDidUpdate` tick. `applicationDidUpdate` is
        // posted after *every* event the app processes (mouse-moved, key, timer, …),
        // so re-running window setup there added main-thread work to every run-loop
        // iteration and contributed to dropped frames during interaction.
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowDidActivate(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
        center.addObserver(self, selector: #selector(windowDidActivate(_:)), name: NSWindow.didBecomeMainNotification, object: nil)
        configureAllWindows()
    }

    @objc private func windowDidActivate(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        configureWindow(window)
    }

    private func configureAllWindows() {
        NSApp.windows.forEach(configureWindow)
    }

    private func configureWindow(_ window: NSWindow) {
        let identifier = ObjectIdentifier(window)
        guard !configuredWindows.contains(identifier) else { return }
        configuredWindows.insert(identifier)
        window.isRestorable = false
        window.restorationClass = nil
        window.identifier = nil
        if window.delegate !== self {
            window.delegate = self
        }
    }

    func window(_ window: NSWindow, willEncodeRestorableState state: NSCoder) {
        // TokenScope persists durable state in SQLite/app storage. Avoid AppKit persistent-UI
        // window snapshots/restoration work during minimize/restore animations.
    }

    func window(_ window: NSWindow, didDecodeRestorableState state: NSCoder) {
        configureWindow(window)
    }
}
