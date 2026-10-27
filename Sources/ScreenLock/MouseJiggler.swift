//
//  MouseJiggler.swift
//  ScreenLock
//
//  Created by Federico Gasperini on 27/10/26.
//

import ApplicationServices
import CoreGraphics
import Foundation

/// Keeps the Mac awake by nudging the mouse pointer one point sideways and
/// straight back, every 20 seconds.
///
/// Unlike the IOKit assertions in [PowerAssertion](PowerAssertion.swift) this
/// produces **real HID events**: besides resetting macOS's idle timer (so no
/// display sleep and no system screen saver/lock screen behind our window), it
/// also looks like genuine user input to anything else watching for it — the
/// presence/"away" detection of chat and meeting apps, for instance.
///
/// The price is a permission: macOS only delivers synthetic events from a
/// process the user has trusted for **Accessibility** (System Settings →
/// Privacy & Security → Accessibility). Without it `CGEvent.post` succeeds and
/// does nothing at all, which is why `isAvailable` is checked before use.
final class MouseJiggler: KeepAwakeStrategy {
    /// One point: enough to reset the idle timer, small enough to go unnoticed
    /// (and the pointer is put straight back anyway).
    private static let nudge: CGFloat = 1

    private var heartbeat: Timer?
    private var isActive = false
    /// `.hidSystemState` makes the events count as system-wide user activity,
    /// exactly like those of a real mouse.
    private let source = CGEventSource(stateID: .hidSystemState)

    let name = "mouse jiggle (HID)"

    /// Synthetic events are only delivered while the app is trusted for
    /// Accessibility. This never prompts; see `requestPermissionIfNeeded()`.
    var isAvailable: Bool { AXIsProcessTrusted() }

    func acquire() {
        guard !isActive else {
            Log.power.debug("acquire() ignored: the jiggler is already running")
            return
        }
        isActive = true

        if source == nil {
            // Events can still be posted from a nil source, they just carry no
            // explicit state id: worth knowing if the idle timer ignores them.
            Log.power.error(
                "CGEventSource(.hidSystemState) is nil: posting the nudges without an explicit source"
            )
        }

        jiggle()

        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            self?.jiggle()
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer
        Log.power.notice("Mouse jiggle active, one nudge every 20s")
    }

    func release() {
        guard isActive else {
            Log.power.debug("release() ignored: the jiggler is not running")
            return
        }
        isActive = false

        heartbeat?.invalidate()
        heartbeat = nil

        Log.power.notice("Mouse jiggle stopped")
    }

    /// Asks macOS for the Accessibility permission, showing its standard
    /// "open System Settings" dialog, unless the app is trusted already. Called
    /// when the user picks this mode in the menu, so the dialog shows up while
    /// they are at the keyboard rather than in the middle of a lock.
    @discardableResult
    func requestPermissionIfNeeded() -> Bool {
        if AXIsProcessTrusted() {
            Log.power.debug("Accessibility already granted: the mouse jiggle can post events")
            return true
        }
        let options =
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        Log.power.notice("Accessibility requested for the mouse jiggle (trusted: \(trusted))")
        return trusted
    }

    /// One point out, one point back. The pointer ends up exactly where the user
    /// left it, and macOS clamps the intermediate position to the display, so a
    /// pointer parked against the right edge is nudged just as well.
    private func jiggle() {
        guard let location = CGEvent(source: nil)?.location else {
            Log.power.error(
                "Cannot read the pointer location: nudge skipped, the Mac may fall asleep")
            return
        }
        post(to: CGPoint(x: location.x + Self.nudge, y: location.y))
        post(to: location)
        Log.power.debug("Pointer nudged at (\(Int(location.x)), \(Int(location.y)))")
    }

    private func post(to point: CGPoint) {
        guard
            let event = CGEvent(
                mouseEventSource: source,
                mouseType: .mouseMoved,
                mouseCursorPosition: point,
                mouseButton: .left  // ignored for .mouseMoved, but not optional
            )
        else {
            Log.power.error(
                "Cannot create the mouseMoved event for (\(Int(point.x)), \(Int(point.y)))")
            return
        }
        event.post(tap: .cghidEventTap)
    }
}
