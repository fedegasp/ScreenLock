//
//  PowerAssertion.swift
//  ScreenLock
//
//  Created by Federico Gasperini on 22/10/26.
//

import IOKit.pwr_mgt
import Foundation

/// Keeps the Mac awake (system + display) while the lock screen is shown, and
/// also stops macOS's own screen saver / lock-screen idle timer from firing —
/// that timer is independent of the sleep-prevention assertions above, so
/// without the periodic "user activity" heartbeat below the real system lock
/// screen would still kick in behind our window after a few idle minutes.
final class PowerAssertion {
    private var systemAssertionID: IOPMAssertionID = 0
    private var displayAssertionID: IOPMAssertionID = 0
    private var userActivityAssertionID: IOPMAssertionID = 0
    private var heartbeat: Timer?
    private var isActive = false
    private let reason = "ScreenLock active" as CFString

    func acquire() {
        guard !isActive else {
            Log.power.debug("acquire() ignored: assertions already held")
            return
        }
        isActive = true

        let systemStatus = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &systemAssertionID
        )
        if systemStatus == kIOReturnSuccess {
            Log.power.debug("PreventUserIdleSystemSleep assertion acquired (id \(self.systemAssertionID))")
        } else {
            // The Mac can still fall asleep under us: expect the lock to vanish
            // behind the system login window after the idle timeout.
            Log.power.error("PreventUserIdleSystemSleep assertion failed: \(describe(status: systemStatus))")
        }

        let displayStatus = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &displayAssertionID
        )
        if displayStatus == kIOReturnSuccess {
            Log.power.debug("PreventUserIdleDisplaySleep assertion acquired (id \(self.displayAssertionID))")
        } else {
            Log.power.error("PreventUserIdleDisplaySleep assertion failed: \(describe(status: displayStatus))")
        }

        declareUserActivity()

        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            self?.declareUserActivity()
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer
        Log.power.notice("Power assertions active, idle-timer heartbeat every 20s")
    }

    private func declareUserActivity() {
        let status = IOPMAssertionDeclareUserActivity(reason, kIOPMUserActiveLocal, &userActivityAssertionID)
        if status == kIOReturnSuccess {
            Log.power.debug("User activity declared (idle timer reset)")
        } else {
            // Without this the real macOS lock screen appears behind our window.
            Log.power.error("IOPMAssertionDeclareUserActivity failed: \(describe(status: status))")
        }
    }

    func release() {
        guard isActive else {
            Log.power.debug("release() ignored: no assertions held")
            return
        }
        isActive = false

        heartbeat?.invalidate()
        heartbeat = nil

        let systemStatus = IOPMAssertionRelease(systemAssertionID)
        if systemStatus != kIOReturnSuccess {
            Log.power.error("Releasing the system-sleep assertion failed: \(describe(status: systemStatus))")
        }

        let displayStatus = IOPMAssertionRelease(displayAssertionID)
        if displayStatus != kIOReturnSuccess {
            Log.power.error("Releasing the display-sleep assertion failed: \(describe(status: displayStatus))")
        }

        Log.power.notice("Power assertions released")
    }
}
