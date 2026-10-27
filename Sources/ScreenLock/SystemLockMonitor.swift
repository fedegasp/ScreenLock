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
        Log.systemLock.debug("Armed (session screen locked: \(Self.isSessionScreenLocked))")
    }

    func disarm() {
        isArmed = false
        sawSystemLock = false
        Log.systemLock.debug("Disarmed")
    }

    @objc private func systemDidLock() {
        let sessionIsLocked = Self.isSessionScreenLocked
        guard isArmed, sessionIsLocked else {
            // Either we are not locked (nothing to do) or the notification does not
            // match the real session state, i.e. some other process posted it.
            Log.systemLock.debug("screenIsLocked ignored (armed: \(self.isArmed), session locked: \(sessionIsLocked))")
            return
        }
        sawSystemLock = true
        Log.systemLock.notice("macOS lock screen appeared while ScreenLock was engaged")
    }

    @objc private func systemDidUnlock() {
        let sessionIsLocked = Self.isSessionScreenLocked
        guard isArmed, sawSystemLock, !sessionIsLocked else {
            Log.systemLock.debug(
                "screenIsUnlocked ignored (armed: \(self.isArmed), saw system lock: \(self.sawSystemLock), session locked: \(sessionIsLocked))"
            )
            return
        }
        sawSystemLock = false
        Log.systemLock.notice("macOS lock screen released: unlocking ScreenLock without a second authentication")
        onSystemUnlocked?()
    }

    private static var isSessionScreenLocked: Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            Log.systemLock.error(
                "CGSessionCopyCurrentDictionary() returned nothing: session state unknown, assuming unlocked")
            return false
        }
        return info["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}
