//
//  KeyableWindow.swift
//  ScreenLock
//
//  Created by Federico Gasperini on 22/10/26.
//

import AppKit

/// A borderless window still needs to become key/main to receive keyboard focus.
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
