//
//  ScreenLockApp.swift
//  ScreenLock
//
//  Created by Federico Gasperini on 22/10/26.
//

import SwiftUI

@main
struct ScreenLockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // No real window: this is a menu-bar-only (LSUIElement) app.
        // The lock screen is managed manually by AppDelegate/LockWindowController.
        Settings {
            EmptyView()
        }
    }
}
