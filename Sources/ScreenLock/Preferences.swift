//
//  Preferences.swift
//  ScreenLock
//
//  Created by Federico Gasperini on 22/10/26.
//

import Combine
import Foundation

/// Look of the full-screen lock window: solid black, a frosted blur of whatever is
/// behind it, or no background at all (the desktop stays visible).
enum LockBackgroundStyle: String, CaseIterable {
    case black
    case glass
    case transparent

    /// Title of the matching item in the status bar menu.
    var menuTitle: String {
        switch self {
        case .black:
            String(localized: "Black Background", comment: "Status bar menu option: the lock screen is filled with solid black.")
        case .glass:
            String(localized: "Glass Background", comment: "Status bar menu option: the lock screen is a frosted/blurred translucent background.")
        case .transparent:
            String(localized: "Transparent Background", comment: "Status bar menu option: the lock screen has no background, the desktop stays visible behind it.")
        }
    }
}

/// User preferences persisted in `UserDefaults`, shared by the status menu and the lock screen.
final class Preferences: ObservableObject {
    private enum Key {
        static let showsStatusItem = "showsStatusItem"
        static let backgroundStyle = "backgroundStyle"
    }

    private let defaults: UserDefaults

    /// Whether the padlock icon is shown in the menu bar. When hidden the app keeps
    /// running and can still be triggered with the global hotkey.
    @Published var showsStatusItem: Bool {
        didSet {
            defaults.set(showsStatusItem, forKey: Key.showsStatusItem)
            Log.preferences.notice("showsStatusItem = \(self.showsStatusItem)")
        }
    }

    /// Background drawn by the lock screen; chosen from the status bar menu.
    @Published var backgroundStyle: LockBackgroundStyle {
        didSet {
            defaults.set(backgroundStyle.rawValue, forKey: Key.backgroundStyle)
            Log.preferences.notice("backgroundStyle = \(self.backgroundStyle.rawValue)")
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.showsStatusItem: true,
            Key.backgroundStyle: LockBackgroundStyle.black.rawValue
        ])
        showsStatusItem = defaults.bool(forKey: Key.showsStatusItem)

        let storedStyle = defaults.string(forKey: Key.backgroundStyle)
        if let storedStyle, LockBackgroundStyle(rawValue: storedStyle) == nil {
            Log.preferences.error("Unknown stored backgroundStyle '\(storedStyle)': falling back to black")
        }
        backgroundStyle = storedStyle.flatMap(LockBackgroundStyle.init(rawValue:)) ?? .black

        Log.preferences.debug("Loaded: showsStatusItem = \(self.showsStatusItem), backgroundStyle = \(self.backgroundStyle.rawValue)")
    }
}
