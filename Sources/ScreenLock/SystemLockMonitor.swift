//
//  SystemLockMonitor.swift
//  ScreenLock
//
//  Created by Federico Gasperini on 22/10/26.
//

import AppKit
import CoreGraphics

/// Watches the macOS lock screen (login window after sleep/lid close, ⌃⌘Q, …)
/// while ScreenLock is engaged. If the system locks and the user then unlocks it,
/// they have already proven their identity to macOS, so `onSystemUnlocked` fires
/// and ScreenLock can release itself instead of asking for Touch ID a second time.
///
/// `com.apple.screenIsLocked`/`screenIsUnlocked` are undocumented distributed
/// notifications that any process can post, so each one is cross-checked against
/// the real session state (`CGSessionCopyCurrentDictionary`): a spoofed "unlocked"
/// is ignored unless the session was genuinely locked and genuinely is not anymore.
final class SystemLockMonitor {
    var onSystemUnlocked: (() -> Void)?

    private var isArmed = false
    private var sawSystemLock = false

    private static let screenIsLocked = Notification.Name("com.apple.screenIsLocked")
    private static let screenIsUnlocked = Notification.Name("com.apple.screenIsUnlocked")

    init() {
        let center = DistributedNotificationCenter.default()
        // `.deliverImmediately`: while the login window is up we are not the active
        // app, and the default (coalescing) behavior would deliver both notifications
        // only later, when the session is already unlocked again.
        center.addObserver(
            self,
            selector: #selector(systemDidLock),
            name: Self.screenIsLocked,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        center.addObserver(
            self,
            selector: #selector(systemDidUnlock),
            name: Self.screenIsUnlocked,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    /// Starts watching; only a system lock that happens from now on counts.
    func arm() {
        isArmed = true
        sawSystemLock = false
    }

    func disarm() {
        isArmed = false
        sawSystemLock = false
    }

    @objc private func systemDidLock() {
        guard isArmed, Self.isSessionScreenLocked else { return }
        sawSystemLock = true
    }

    @objc private func systemDidUnlock() {
        guard isArmed, sawSystemLock, !Self.isSessionScreenLocked else { return }
        sawSystemLock = false
        onSystemUnlocked?()
    }

    private static var isSessionScreenLocked: Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return info["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}
