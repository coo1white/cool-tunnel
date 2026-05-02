// App/AppDelegate.swift
//
// Window lifecycle: hides the window on Cmd+W instead of destroying it,
// keeps the app alive after the last window closes, and re-shows the window
// when the dock icon is clicked.

import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    nonisolated override init() { super.init() }

    private var commandWMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installCommandWHandler()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            for window in sender.windows {
                window.makeKeyAndOrderFront(nil)
            }
        }
        return true
    }

    private func installCommandWHandler() {
        commandWMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { @MainActor event in
            guard event.modifierFlags.contains(.command),
                event.charactersIgnoringModifiers == "w"
            else {
                return event
            }
            NSApp.keyWindow?.orderOut(nil)
            return nil
        }
    }

    // Note: The previous Swift implementation observed
    // `NSWindow.willCloseNotification` to hide rather than close the window.
    // With Swift 6 strict concurrency that observer pattern can't be
    // expressed safely without `@unchecked Sendable` shims, so we drop it
    // here. `applicationShouldTerminateAfterLastWindowClosed` already keeps
    // the app alive after the window closes; the Dock-icon reopen handler
    // brings it back. The Cmd-W shortcut still hides the window.
}
