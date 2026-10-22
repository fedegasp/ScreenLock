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
        guard windows.isEmpty else { return }

        windows = NSScreen.screens.map { screen in
            makeWindow(for: screen)
        }

        windows.forEach { $0.orderFrontRegardless() }
        windows.first?.makeKeyAndOrderFront(nil)
    }

    func rebuildForCurrentScreens() {
        guard !windows.isEmpty else { return }
        hide()
        show()
    }

    /// Re-asserts topmost/key status, e.g. after another app tried to steal focus.
    func bringToFront() {
        windows.forEach { $0.orderFrontRegardless() }
        windows.first?.makeKeyAndOrderFront(nil)
    }

    func hide() {
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

        window.isOpaque = true
        window.backgroundColor = .black
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isMovable = false
        window.ignoresMouseEvents = false // capture input so it cannot reach apps below
        window.hidesOnDeactivate = false
        window.setFrame(screen.frame, display: true)

        let hostingView = NSHostingView(rootView: LockView(coordinator: coordinator, preferences: preferences))
        hostingView.frame = window.contentRect(forFrameRect: window.frame)
        window.contentView = hostingView

        return window
    }
}
