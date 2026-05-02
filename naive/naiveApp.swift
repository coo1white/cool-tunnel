//
//  naiveApp.swift
//  naive
//
//  Created by ***REDACTED*** on 5/2/26.
//

import SwiftUI
import AppKit

@main
struct naiveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 820, height: 700)
        .windowResizability(.contentSize)
        .windowBackgroundDragBehavior(.enabled)
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var commandWMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyWindowCloseHandling()
        commandWMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
                  event.charactersIgnoringModifiers?.lowercased() == "w" else {
                return event
            }

            NSApplication.shared.keyWindow?.orderOut(nil)
            return nil
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeVisible),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let commandWMonitor {
            NSEvent.removeMonitor(commandWMonitor)
        }
        NotificationCenter.default.removeObserver(self)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc private func windowDidBecomeVisible(_ notification: Notification) {
        applyWindowCloseHandling()
    }

    private func applyWindowCloseHandling() {
        for window in NSApplication.shared.windows where window.isVisible || window.title == "Cool tunnel" {
            window.delegate = self
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}
