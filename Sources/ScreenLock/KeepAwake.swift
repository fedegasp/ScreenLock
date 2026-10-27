//
//  KeepAwake.swift
//  ScreenLock
//
//  Created by Federico Gasperini on 27/10/26.
//

import Foundation

/// One way of keeping the Mac awake while the lock screen is shown. Both
/// implementations ([PowerAssertion](PowerAssertion.swift) and
/// [MouseJiggler](MouseJiggler.swift)) are idempotent: a second `acquire()` or a
/// `release()` with nothing held is a no-op.
protocol KeepAwakeStrategy: AnyObject {
    /// Short name used in the logs.
    var name: String { get }

    /// Whether the strategy can actually do its job right now (permissions and
    /// anything else it needs). A strategy that is unavailable is never used:
    /// `KeepAwake` falls back to the IOKit one.
    var isAvailable: Bool { get }

    func acquire()
    func release()
}

/// Keeps the Mac awake while locked, through the mechanism chosen in the
/// preferences, and follows that choice when it changes mid-lock.
final class KeepAwake {
    private let powerAssertion = PowerAssertion()
    private let mouseJiggler = MouseJiggler()

    /// The strategy currently holding the Mac awake, `nil` while unlocked.
    private var active: KeepAwakeStrategy?

    func acquire(mode: KeepAwakeMode) {
        guard active == nil else {
            Log.power.debug(
                "acquire() ignored: \(self.active?.name ?? "a strategy") is already active")
            return
        }
        let strategy = strategy(for: mode)
        Log.power.notice("Keeping the Mac awake with \(strategy.name)")
        strategy.acquire()
        active = strategy
    }

    func release() {
        guard let active else { return }
        active.release()
        self.active = nil
    }

    /// Reacts to the menu switching mode: does nothing unless the Mac is being
    /// kept awake right now, in which case the old mechanism is swapped out for
    /// the new one without a gap long enough for the idle timer to notice.
    func setMode(_ mode: KeepAwakeMode) {
        guard let active else { return }
        let strategy = strategy(for: mode)
        guard strategy !== active else { return }

        Log.power.notice("Switching from \(active.name) to \(strategy.name) while locked")
        strategy.acquire()
        active.release()
        self.active = strategy
    }

    /// Asks for the permission the HID mode needs, if it is not granted yet. See
    /// [MouseJiggler.requestPermissionIfNeeded()](MouseJiggler.swift).
    @discardableResult
    func requestHIDPermissionIfNeeded() -> Bool {
        mouseJiggler.requestPermissionIfNeeded()
    }

    private func strategy(for mode: KeepAwakeMode) -> KeepAwakeStrategy {
        switch mode {
        case .ioKit:
            return powerAssertion
        case .hid:
            guard mouseJiggler.isAvailable else {
                // Without Accessibility the synthetic mouse events are dropped on
                // the floor and the Mac would fall asleep behind the lock window.
                Log.power.error(
                    "\(self.mouseJiggler.name) unavailable (ScreenLock is not trusted for Accessibility): using \(self.powerAssertion.name) instead"
                )
                return powerAssertion
            }
            return mouseJiggler
        }
    }
}
