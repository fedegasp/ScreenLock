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
        guard !isActive else { return }
        isActive = true

        IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &systemAssertionID
        )

        IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &displayAssertionID
        )

        declareUserActivity()

        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            self?.declareUserActivity()
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer
    }

    private func declareUserActivity() {
        IOPMAssertionDeclareUserActivity(reason, kIOPMUserActiveLocal, &userActivityAssertionID)
    }

    func release() {
        guard isActive else { return }
        isActive = false

        heartbeat?.invalidate()
        heartbeat = nil

        IOPMAssertionRelease(systemAssertionID)
        IOPMAssertionRelease(displayAssertionID)
    }
}
