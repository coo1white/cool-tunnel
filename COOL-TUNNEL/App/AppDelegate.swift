// App/AppDelegate.swift
//
// Window lifecycle for v0.1.5.8 single-window app:
//
//   - Cmd+W hides the window (orderOut), doesn't close it.
//   - Closing the last window doesn't quit the app.
//   - Dock-icon click / `Window` menu reopen brings the same hidden
//     window back to the front (does *not* create a new one — the
//     `Window(_:id:)` scene in `CoolTunnelApp` is single-instance
//     by construction; the previous `WindowGroup` could create
//     extra windows on reopen).
//   - The engine subprocess only shuts down on real app termination,
//     not on window hide. The view's `.onDisappear` is no longer
//     wired to `orchestrator.shutdown()` — that fired on Cmd+W and
//     killed the engine, leaving subsequent reopens dead.

import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    nonisolated override init() { super.init() }

    private var commandWMonitor: Any?

    /// Set by the SwiftUI scene's `.task` once bootstrap finishes.
    /// `applicationWillTerminate` reads it to perform a clean
    /// engine shutdown on real quit.
    var orchestrator: TunnelOrchestrator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installCommandWHandler()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Hidden windows still count as "windows", so this only
        // fires on real close. Returning false keeps the app alive
        // so the dock-icon reopen path can show the window again.
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        // If a window is already visible, AppKit will just bring
        // the app forward — nothing for us to do. Returning true
        // tells AppKit that case is handled too.
        guard !flag else { return true }
        // No visible window. Find the single main window (there
        // can only be one — `Window(_:id:)` scene) and bring it
        // back. Earlier versions iterated `sender.windows` and
        // showed *every* hidden window, which produced the
        // multi-window-on-reopen bug after a few hide/show cycles.
        if let mainWindow = mainWindow(in: sender) {
            mainWindow.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Real quit (Cmd+Q, menu Quit, system shutdown). Detach
        // the engine cleanly — it'll revert any active system
        // proxy and stop the supervisor before we exit.
        if let orchestrator {
            // `applicationWillTerminate` is allowed up to a few
            // hundred ms of synchronous work; we run shutdown on
            // a Task and wait briefly. The OS will SIGTERM us
            // either way, and the engine handles SIGCHLD on its
            // own — this is best-effort cleanup.
            let semaphore = DispatchSemaphore(value: 0)
            Task { @MainActor in
                await orchestrator.shutdown()
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + .milliseconds(500))
        }
    }

    /// Returns the Window-scene main window. Filters out any
    /// floating panels or auxiliary windows AppKit might have
    /// created (status bar, accessory). The `Window(_:id:)` scene
    /// gives its window a stable identifier we can match against;
    /// fall back to "the only window with our content size" when
    /// the identifier match misses.
    private func mainWindow(in app: NSApplication) -> NSWindow? {
        // Prefer the SwiftUI-tagged main window. SwiftUI sets the
        // window's `identifier` to match the `Window` scene's id.
        if let tagged = app.windows.first(where: { $0.identifier?.rawValue == WindowID.main }) {
            return tagged
        }
        // Fallback: any non-floating, non-utility window. There
        // should only be one in the single-Window scene.
        return app.windows.first { window in
            !window.isFloatingPanel
                && window.styleMask.contains(.titled)
        }
    }

    private func installCommandWHandler() {
        commandWMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { @MainActor event in
            guard event.modifierFlags.contains(.command),
                event.charactersIgnoringModifiers == "w"
            else {
                return event
            }
            // While Settings is shown, the SettingsView's Back
            // button has its own .keyboardShortcut("w", .command)
            // and gets the event first via SwiftUI's responder
            // chain. We only see Cmd+W here when no other
            // responder claimed it — so this is the "main view
            // is showing, hide the whole window" path.
            NSApp.keyWindow?.orderOut(nil)
            return nil
        }
    }
}
