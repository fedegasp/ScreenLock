//
//  LockWindowController.swift
//  ScreenLock
//
//  Created by Federico Gasperini on 22/10/26.
//

import AppKit
import SwiftUI

/// Creates one borderless, topmost, non-interactive-content window per connected
/// display, so the lock screen covers every monitor.
final class LockWindowController {
    private var windows: [NSWindow] = []
    private let coordinator: LockCoordinator
    private let preferences: Preferences

    init(coordinator: LockCoordinator, preferences: Preferences) {
        self.coordinator = coordinator
        self.preferences = preferences
    }

    var isShowing: Bool { !windows.isEmpty }

    func show() {
        guard windows.isEmpty else {
            Log.window.debug("show() ignored: \(self.windows.count) window(s) already on screen")
            return
        }

        let screens = NSScreen.screens
        if screens.isEmpty {
            // Nothing would cover the display: the lock would engage invisibly.
            Log.window.error("NSScreen.screens is empty: no lock window will be created")
        }

        windows = screens.map { screen in
            makeWindow(for: screen)
        }

        windows.forEach { $0.orderFrontRegardless() }
        windows.first?.makeKeyAndOrderFront(nil)

        Log.window.notice("\(self.windows.count) lock window(s) shown; key window: \(self.windows.first?.isKeyWindow ?? false)")
    }

    func rebuildForCurrentScreens() {
        guard !windows.isEmpty else { return }
        Log.window.notice("Display configuration changed: rebuilding the lock windows")
        hide()
        show()
    }

    /// Re-asserts topmost/key status, e.g. after another app tried to steal focus.
    func bringToFront() {
        windows.forEach { $0.orderFrontRegardless() }
        windows.first?.makeKeyAndOrderFront(nil)
        Log.window.debug("Brought to front; key window: \(self.windows.first?.isKeyWindow ?? false)")
    }

    func hide() {
        Log.window.notice("Hiding \(self.windows.count) lock window(s)")
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }

    private func makeWindow(for screen: NSScreen) -> NSWindow {
        let window = KeyableWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )

        // The background is drawn by `LockView` (black, glass or nothing at all), so
        // the window itself stays clear and the style can change while locked.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isMovable = false
        window.ignoresMouseEvents = false // capture input so it cannot reach apps below
        window.hidesOnDeactivate = false
        window.setFrame(screen.frame, display: true)

        let hostingView = NSHostingView(rootView: LockView(coordinator: coordinator, preferences: preferences))
        hostingView.frame = window.contentRect(forFrameRect: window.frame)
        window.contentView = hostingView

        let frame = screen.frame
        Log.window.debug("Window created for screen \(Int(frame.width))x\(Int(frame.height)) at (\(Int(frame.origin.x)), \(Int(frame.origin.y))), style \(preferences.backgroundStyle.rawValue)")

        return window
    }
}
