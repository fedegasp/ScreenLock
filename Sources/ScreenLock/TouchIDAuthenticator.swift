//
//  TouchIDAuthenticator.swift
//  ScreenLock
//
//  Created by Federico Gasperini on 22/10/26.
//

import LocalAuthentication

enum AuthOutcome {
    case success
    case failure(String)
}

/// Thin wrapper around LocalAuthentication. Touch ID is required whenever it is
/// usable (no "Use Password…" button); the login password is asked for only when
/// Touch ID is unavailable (no sensor, not enrolled, lid closed, lockout, …).
final class TouchIDAuthenticator {
    /// Contexts whose prompt is still on screen, so they can be dismissed on unlock.
    private var pendingContexts = Set<LAContext>()

    /// Pre-flight check so the app never engages the kiosk lock on a Mac where
    /// neither Touch ID nor the login password can be used to release it.
    func isAuthenticationAvailable() -> Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    func authenticate(reason: String, completion: @escaping (AuthOutcome) -> Void) {
        let context = LAContext()
        context.localizedCancelTitle = String(localized: "Cancel", comment: "Cancel button title of the Touch ID/password prompt.")
        context.touchIDAuthenticationAllowableReuseDuration = 0

        let policy: LAPolicy
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) {
            policy = .deviceOwnerAuthenticationWithBiometrics
            context.localizedFallbackTitle = "" // hide "Use Password…" while Touch ID works
        } else {
            policy = .deviceOwnerAuthentication // goes straight to the password prompt
        }

        var error: NSError?
        guard context.canEvaluatePolicy(policy, error: &error) else {
            let message = error?.localizedDescription ?? String(
                localized: "Authentication is not available on this Mac.",
                comment: "Fallback message shown on the lock screen when no authentication policy can be evaluated."
            )
            completion(.failure(message))
            return
        }

        pendingContexts.insert(context)
        context.evaluatePolicy(policy, localizedReason: reason) { success, evalError in
            DispatchQueue.main.async {
                self.pendingContexts.remove(context)
                if success {
                    completion(.success)
                } else {
                    let message = (evalError as NSError?)?.localizedDescription ?? String(
                        localized: "Authentication failed.",
                        comment: "Fallback message shown on the lock screen when Touch ID/password verification fails without a system error description."
                    )
                    completion(.failure(message))
                }
            }
        }
    }

    /// Dismisses every prompt still on screen; their completions report a failure.
    func cancelPendingAuthentications() {
        pendingContexts.forEach { $0.invalidate() }
    }
}
