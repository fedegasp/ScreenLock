//
//  AppDelegate.swift
//  ScreenLock
//
//  Created by Federico Gasperini on 22/10/26.
//

import AppKit
import Carbon.HIToolbox
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotKey: GlobalHotKey?
    private var cancellables = Set<AnyCancellable>()

    private let preferences = Preferences()
    private let coordinator = LockCoordinator()
    private lazy var lockWindowController = LockWindowController(coordinator: coordinator, preferences: preferences)
    private let authenticator = TouchIDAuthenticator()
    private let powerAssertion = PowerAssertion()
    private let systemLockMonitor = SystemLockMonitor()

    private var isLocked = false
    /// Number of LocalAuthentication prompts currently on screen (the hotkey can
    /// start a new one before the previous completes).
    private var pendingAuthentications = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupGlobalHotKey()

        // If macOS's own lock screen appears while we're locked (lid closed, sleep,
        // ⌃⌘Q) the user already authenticates there: don't ask a second time.
        systemLockMonitor.onSystemUnlocked = { [weak self] in
            self?.unlockScreen()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // macOS automatically reverts presentationOptions when the app resigns
        // active status, so if another process activates itself while we're
        // locked, Cmd+Tab/Force Quit/Dock would silently come back. Fight back.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )

        // The Touch ID/password panel belongs to a system agent process: while it is
        // up we must let it become active, otherwise the password field never gets
        // keyboard focus. We still react if a regular app is brought forward.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(otherAppDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Refuse to quit while the lock screen is active: only authentication releases it.
        isLocked ? .terminateCancel : .terminateNow
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "ScreenLock")
            button.action = #selector(statusItemClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Emits the stored value immediately, then every change (menu or lock screen switch).
        preferences.$showsStatusItem
            .sink { [weak self] isVisible in
                self?.statusItem.isVisible = isVisible
            }
            .store(in: &cancellables)
    }

    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showMenu()
        } else {
            handleHotKeyTriggered()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(
            withTitle: String(localized: "Lock Now (⌃⌥⌘L)", comment: "Status bar menu item that locks the screen; the shortcut in parentheses is the global hotkey."),
            action: #selector(lockFromMenu),
            keyEquivalent: ""
        ).target = self
        menu.addItem(.separator())

        let showIconItem = NSMenuItem(
            title: String(localized: "Show Menu Bar Icon", comment: "Status bar menu toggle; when off the menu bar icon is hidden and the app stays reachable through the global hotkey."),
            action: #selector(toggleStatusItemVisibility),
            keyEquivalent: ""
        )
        showIconItem.target = self
        showIconItem.state = preferences.showsStatusItem ? .on : .off
        menu.addItem(showIconItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: String(localized: "Quit", comment: "Status bar menu item that quits the app."),
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        quitItem.isEnabled = !isLocked
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil // one-shot menu; left-click keeps locking directly
    }

    @objc private func lockFromMenu() {
        guard !isLocked else { return }
        lockScreen()
    }

    @objc private func toggleStatusItemVisibility() {
        preferences.showsStatusItem.toggle()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Global hotkey (⌃⌥⌘L)

    private func setupGlobalHotKey() {
        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        hotKey = GlobalHotKey(keyCode: UInt32(kVK_ANSI_L), modifiers: modifiers) { [weak self] in
            self?.handleHotKeyTriggered()
        }
    }

    private func handleHotKeyTriggered() {
        if isLocked {
            retryAuthentication()
        } else {
            lockScreen()
        }
    }

    // MARK: - Lock / unlock

    private func lockScreen() {
        guard !isLocked else { return }

        guard authenticator.isAuthenticationAvailable() else {
            let alert = NSAlert()
            alert.messageText = String(
                localized: "Authentication Unavailable",
                comment: "Alert title shown when the lock cannot be engaged because no authentication method is available."
            )
            alert.informativeText = String(
                localized: "The lock can't be engaged: neither Touch ID nor the login password can be verified on this Mac (or in this session). To avoid getting locked out, the lock won't be activated.",
                comment: "Alert message explaining why the lock was not engaged."
            )
            alert.alertStyle = .warning
            alert.runModal()
            return
        }

        isLocked = true

        // The authentication prompt is not shown automatically: the screen stays
        // black until the user asks for it with ⌃⌥⌘L, so locking never steals the
        // keyboard or pops a Touch ID panel while walking away.
        coordinator.phase = .idle
        systemLockMonitor.arm()
        powerAssertion.acquire()
        lockWindowController.show()
        reassertLock()
    }

    @objc private func appDidResignActive() {
        // During authentication the decision is left to `otherAppDidActivate`.
        guard isLocked, pendingAuthentications == 0 else { return }
        reassertLock()
    }

    @objc private func otherAppDidActivate(_ notification: Notification) {
        guard isLocked, pendingAuthentications > 0 else { return }
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        guard let app, app != NSRunningApplication.current else { return }
        // System auth agents are background/UI-element processes; a `.regular` app
        // means something (e.g. Cmd+Tab while the panel is up) is escaping the lock.
        if app.activationPolicy == .regular {
            reassertLock()
        }
    }

    private func reassertLock() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.presentationOptions = [
            .disableProcessSwitching,
            .disableForceQuit,
            .disableSessionTermination,
            .disableHideApplication,
            .disableAppleMenu,
            .hideDock,
            .hideMenuBar
        ]
        lockWindowController.bringToFront()
    }

    private func unlockScreen() {
        guard isLocked else { return }
        isLocked = false

        systemLockMonitor.disarm()
        authenticator.cancelPendingAuthentications()
        NSApp.presentationOptions = []
        lockWindowController.hide()
        powerAssertion.release()
        coordinator.phase = .idle
    }

    private func retryAuthentication() {
        guard isLocked else { return }
        coordinator.phase = .authenticating
        pendingAuthentications += 1

        let reason = String(
            localized: "unlock the screen",
            comment: "Reason passed to LocalAuthentication; macOS displays it as “ScreenLock is trying to <reason>.”, so it must complete that sentence."
        )
        authenticator.authenticate(reason: reason) { [weak self] outcome in
            guard let self else { return }
            self.pendingAuthentications -= 1
            guard self.isLocked else { return }
            switch outcome {
            case .success:
                self.unlockScreen()
            case .failure(let message):
                self.coordinator.phase = .failed(message)
                // The auth panel took activation away, so presentationOptions were
                // reverted by macOS: take focus back now that the panel is gone.
                if self.pendingAuthentications == 0 {
                    self.reassertLock()
                }
            }
        }
    }

    @objc private func screenParametersChanged() {
        guard isLocked else { return }
        lockWindowController.rebuildForCurrentScreens()
    }
}
