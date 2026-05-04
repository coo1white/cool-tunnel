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
    private var wakeObserver: NSObjectProtocol?

    /// Set by the SwiftUI scene's `.task` once bootstrap finishes.
    /// `applicationWillTerminate` reads it to perform a clean
    /// engine shutdown on real quit.
    var orchestrator: TunnelOrchestrator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installCommandWHandler()
        installSleepWakeHandlers()
    }

    /// **UX-F#4 (v0.1.7.18):** subscribe to
    /// `NSWorkspace.didWakeNotification` so the orchestrator
    /// can probe engine health after the system returns from
    /// sleep. Without this, a Mac that sleeps for >30 minutes
    /// often has its TCP keepalives dropped — `naive` is alive
    /// but every browser request stalls because the upstream
    /// connection is dead, and the UI keeps showing "Active"
    /// with no recovery hint. The orchestrator surfaces a
    /// clear `lastError` (rendered in `HeaderView` per
    /// v0.1.7.17 UX-F#1) so the user knows to restart the mode.
    private func installSleepWakeHandlers() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // The closure is delivered on `.main` queue.
            // Hop into a `@MainActor` Task so the
            // `self?.orchestrator` read is actor-isolated
            // (Swift 6 strict concurrency forbids the read
            // directly inside this Sendable closure).
            Task { @MainActor [weak self] in
                guard let orchestrator = self?.orchestrator else { return }
                await orchestrator.handleSystemDidWake()
            }
        }
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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Real quit (Cmd+Q, menu Quit, system shutdown). The
        // previous implementation parked the main thread on a
        // `DispatchSemaphore` while a `Task @MainActor` tried to
        // run shutdown — the MainActor IS the main thread, so the
        // task could never run and the 500ms wait always elapsed
        // with the engine still alive (system proxy left enabled,
        // naive child PID lingering until the kernel reaped it).
        //
        // The correct AppKit dance is `.terminateLater` + a real
        // async task that calls `NSApp.reply(toApplicationShouldTerminate:)`
        // when shutdown finishes. The runloop keeps spinning, the
        // MainActor-isolated `orchestrator.shutdown()` runs, and
        // we tell AppKit to proceed once the engine is genuinely
        // down.
        guard let orchestrator else {
            return .terminateNow
        }
        // Two parallel tasks race to send `reply(toApplicationShouldTerminate:)`:
        // (1) the real shutdown task; (2) a 5-second watchdog. Whichever
        // wins, AppKit gets one reply. Without the watchdog any future
        // shutdown-step hang (signal-blocked syscall, network-stack
        // teardown, system-proxy revert blocked on a wedged
        // `networksetup`) would park the app in "terminating…" forever
        // with the engine + system proxy still alive — far worse than
        // a 5 s wait followed by a slightly-dirty exit.
        // **Lifecycle-F#5 (v0.1.7.19):** keep a handle on the
        // shutdown Task so the watchdog can cancel it on
        // expiry. Without the cancel, a shutdown that finishes
        // at t=8s (after the watchdog already replied at t=5s)
        // continues running its body — calling `core.stop()` /
        // `disableAll()` against a partially-released graph
        // while AppKit is mid-teardown.
        let replied = NSAppTerminateReplyOnce()
        let shutdownTask = Task { @MainActor in
            await orchestrator.shutdown()
            replied.fire()
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            shutdownTask.cancel()
            replied.fire()
        }
        return .terminateLater
    }

    /// Single-shot reply gate. AppKit treats a second
    /// `reply(toApplicationShouldTerminate:)` as undefined behaviour
    /// (some macOS versions assert); this keeps the contract.
    /// MainActor-isolated so both racer Tasks already serialise on
    /// it via Swift's actor model, no extra lock needed.
    @MainActor
    private final class NSAppTerminateReplyOnce {
        private var fired = false
        func fire() {
            guard !fired else { return }
            fired = true
            NSApp.reply(toApplicationShouldTerminate: true)
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

    // **UX-F#4 (v0.1.7.18):** no `deinit`-based observer
    // cleanup. Swift 6 strict concurrency forbids accessing
    // `@MainActor`-isolated stored properties from a
    // `nonisolated` deinit, and AppDelegate is process-lived
    // so the observer leak is purely theoretical (it goes
    // away when the process exits anyway). If we ever build
    // a test harness that creates/destroys AppDelegate
    // instances, add a `tearDown(_:)` method that explicitly
    // removes the observer on the main actor.

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
