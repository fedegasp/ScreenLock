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
        var error: NSError?
        let isAvailable = LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
        if !isAvailable {
            Log.auth.error("deviceOwnerAuthentication unavailable: \(error?.localizedDescription ?? "no error") (code \(error?.code ?? 0))")
        }
        return isAvailable
    }

    func authenticate(reason: String, completion: @escaping (AuthOutcome) -> Void) {
        let context = LAContext()
        context.localizedCancelTitle = String(localized: "Cancel", comment: "Cancel button title of the Touch ID/password prompt.")
        context.touchIDAuthenticationAllowableReuseDuration = 0

        let policy: LAPolicy
        var biometricsError: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &biometricsError) {
            policy = .deviceOwnerAuthenticationWithBiometrics
            context.localizedFallbackTitle = "" // hide "Use Password…" while Touch ID works
            Log.auth.notice("Using Touch ID (biometryType \(context.biometryType.rawValue))")
        } else {
            policy = .deviceOwnerAuthentication // goes straight to the password prompt
            Log.auth.notice("Touch ID unusable, falling back to the login password: \(biometricsError?.localizedDescription ?? "no error") (code \(biometricsError?.code ?? 0))")
        }

        var error: NSError?
        guard context.canEvaluatePolicy(policy, error: &error) else {
            let message = error?.localizedDescription ?? String(
                localized: "Authentication is not available on this Mac.",
                comment: "Fallback message shown on the lock screen when no authentication policy can be evaluated."
            )
            Log.auth.error("No evaluable policy: \(message) (code \(error?.code ?? 0))")
            completion(.failure(message))
            return
        }

        pendingContexts.insert(context)
        Log.auth.debug("Showing the authentication prompt (\(self.pendingContexts.count) on screen)")

        context.evaluatePolicy(policy, localizedReason: reason) { success, evalError in
            DispatchQueue.main.async {
                self.pendingContexts.remove(context)
                if success {
                    Log.auth.notice("Authentication succeeded")
                    completion(.success)
                } else {
                    let nsError = evalError as NSError?
                    let message = nsError?.localizedDescription ?? String(
                        localized: "Authentication failed.",
                        comment: "Fallback message shown on the lock screen when Touch ID/password verification fails without a system error description."
                    )
                    // Codes worth recognizing: -2 userCancel, -4 systemCancel,
                    // -8 biometryLockout, -9 appCancel (our own invalidate()).
                    Log.auth.notice("Authentication failed: \(message) (code \(nsError?.code ?? 0))")
                    completion(.failure(message))
                }
            }
        }
    }

    /// Dismisses every prompt still on screen; their completions report a failure.
    func cancelPendingAuthentications() {
        guard !pendingContexts.isEmpty else { return }
        Log.auth.debug("Dismissing \(self.pendingContexts.count) pending prompt(s)")
        pendingContexts.forEach { $0.invalidate() }
    }
}
