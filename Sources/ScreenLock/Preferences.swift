//
//  Preferences.swift
//  ScreenLock
//
//  Created by Federico Gasperini on 22/10/26.
//

import Combine
import Foundation

/// User preferences persisted in `UserDefaults`, shared by the status menu and the lock screen.
final class Preferences: ObservableObject {
    private enum Key {
        static let showsStatusItem = "showsStatusItem"
    }

    private let defaults: UserDefaults

    /// Whether the padlock icon is shown in the menu bar. When hidden the app keeps
    /// running and can still be triggered with the global hotkey.
    @Published var showsStatusItem: Bool {
        didSet { defaults.set(showsStatusItem, forKey: Key.showsStatusItem) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Key.showsStatusItem: true])
        showsStatusItem = defaults.bool(forKey: Key.showsStatusItem)
    }
}
