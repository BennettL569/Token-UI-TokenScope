import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        NSWindow.allowsAutomaticWindowTabbing = false
        configureAllWindows()
    }

    func applicationDidUpdate(_ notification: Notification) {
        configureAllWindows()
    }

    private func configureAllWindows() {
        NSApp.windows.forEach(configureWindow)
    }

    private func configureWindow(_ window: NSWindow) {
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
