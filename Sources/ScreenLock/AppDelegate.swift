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
    private lazy var lockWindowController = LockWindowController(
        coordinator: coordinator, preferences: preferences)
    private let authenticator = TouchIDAuthenticator()
    private let keepAwake = KeepAwake()
    private let systemLockMonitor = SystemLockMonitor()

    private var isLocked = false
    /// Number of LocalAuthentication prompts currently on screen (the hotkey can
    /// start a new one before the previous completes).
    private var pendingAuthentications = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before anything else: open the log file, then arm the crash handlers so
        // an early failure still leaves a trace.
        Log.start()
        CrashReporter.install()

        let version =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        Log.app.notice(
            "ScreenLock \(version) (\(build)) launched, \(NSScreen.screens.count) screen(s)")
        Log.app.notice("Readable log file: \(Log.fileURL?.path ?? "unavailable")")

        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupGlobalHotKey()

        // Picking another keep-awake mode from the menu while the screen is
        // already locked swaps the mechanism in place (no-op when unlocked).
        preferences.$keepAwakeMode
            .dropFirst()  // the stored value is read by lockScreen() itself
            .sink { [weak self] mode in
                self?.keepAwake.setMode(mode)
            }
            .store(in: &cancellables)

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
        if isLocked {
            Log.app.notice("Termination refused: the screen is locked")
            return .terminateCancel
        }
        Log.app.notice("Terminating")
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.app.notice("=== ScreenLock exited cleanly ===")
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if statusItem.button == nil {
            // Without a button there is no icon and no left-click: only the hotkey left.
            Log.app.error("The status item has no button: the menu bar icon will not respond")
        }
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "lock.fill", accessibilityDescription: "ScreenLock")
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
        guard let event = NSApp.currentEvent else {
            Log.app.error("Status item clicked but NSApp.currentEvent is nil: click ignored")
            return
        }
        if event.type == .rightMouseUp {
            showMenu()
        }
        else {
            handleHotKeyTriggered()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(
            withTitle: String(
                localized: "Lock Now (⌃⌥⌘L)",
                comment:
                    "Status bar menu item that locks the screen; the shortcut in parentheses is the global hotkey."
            ),
            action: #selector(lockFromMenu),
            keyEquivalent: ""
        ).target = self
        menu.addItem(.separator())

        let showIconItem = NSMenuItem(
            title: String(
                localized: "Show Menu Bar Icon",
                comment:
                    "Status bar menu toggle; when off the menu bar icon is hidden and the app stays reachable through the global hotkey."
            ),
            action: #selector(toggleStatusItemVisibility),
            keyEquivalent: ""
        )
        showIconItem.target = self
        showIconItem.state = preferences.showsStatusItem ? .on : .off
        menu.addItem(showIconItem)
        menu.addItem(.separator())

        for style in LockBackgroundStyle.allCases {
            let item = NSMenuItem(
                title: style.menuTitle,
                action: #selector(selectBackgroundStyle(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = style
            item.state = preferences.backgroundStyle == style ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let keepAwakeItem = NSMenuItem(
            title: String(
                localized: "Keep Mac Awake",
                comment:
                    "Status bar submenu listing how the Mac is kept awake while the screen is locked."
            ),
            action: nil,
            keyEquivalent: ""
        )
        let keepAwakeMenu = NSMenu()
        for mode in KeepAwakeMode.allCases {
            let item = NSMenuItem(
                title: mode.menuTitle,
                action: #selector(selectKeepAwakeMode(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = mode
            item.state = preferences.keepAwakeMode == mode ? .on : .off
            keepAwakeMenu.addItem(item)
        }
        keepAwakeItem.submenu = keepAwakeMenu
        menu.addItem(keepAwakeItem)
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
        statusItem.menu = nil  // one-shot menu; left-click keeps locking directly
    }

    @objc private func lockFromMenu() {
        guard !isLocked else { return }
        lockScreen()
    }

    @objc private func toggleStatusItemVisibility() {
        preferences.showsStatusItem.toggle()
    }

    @objc private func selectBackgroundStyle(_ sender: NSMenuItem) {
        guard let style = sender.representedObject as? LockBackgroundStyle else { return }
        preferences.backgroundStyle = style
    }

    @objc private func selectKeepAwakeMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? KeepAwakeMode else { return }
        preferences.keepAwakeMode = mode
        if mode == .hid {
            // Synthetic mouse events go nowhere until ScreenLock is trusted for
            // Accessibility: ask now, while the user is right here, rather than
            // discovering it at the next lock (where we fall back to IOKit).
            keepAwake.requestHIDPermissionIfNeeded()
        }
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
        if hotKey == nil {
            // GlobalHotKey has already logged the OSStatus; this is the consequence:
            // with the menu bar icon hidden the app becomes unreachable.
            Log.hotkey.error("⌃⌥⌘L is not available: the app can only be driven from the menu bar icon")
        }
    }

    private func handleHotKeyTriggered() {
        Log.lock.debug("Trigger received (locked: \(self.isLocked))")
        if isLocked {
            retryAuthentication()
        }
        else {
            lockScreen()
        }
    }

    // MARK: - Lock / unlock

    private func lockScreen() {
        guard !isLocked else { return }

        guard authenticator.isAuthenticationAvailable() else {
            Log.lock.error("Lock refused: no authentication method available on this Mac/session")
            let alert = NSAlert()
            alert.messageText = String(
                localized: "Authentication Unavailable",
                comment:
                    "Alert title shown when the lock cannot be engaged because no authentication method is available."
            )
            alert.informativeText = String(
                localized:
                    "The lock can't be engaged: neither Touch ID nor the login password can be verified on this Mac (or in this session). To avoid getting locked out, the lock won't be activated.",
                comment: "Alert message explaining why the lock was not engaged."
            )
            alert.alertStyle = .warning
            alert.runModal()
            return
        }

        isLocked = true
        Log.lock.notice(
            "Locking (\(NSScreen.screens.count) screen(s), style \(self.preferences.backgroundStyle.rawValue))")

        // The authentication prompt is not shown automatically: the screen stays
        // black until the user asks for it with ⌃⌥⌘L, so locking never steals the
        // keyboard or pops a Touch ID panel while walking away.
        coordinator.phase = .idle
        systemLockMonitor.arm()
        keepAwake.acquire(mode: preferences.keepAwakeMode)
        lockWindowController.show()
        reassertLock()
        Log.lock.notice("Locked")
    }

    @objc private func appDidResignActive() {
        // During authentication the decision is left to `otherAppDidActivate`.
        guard isLocked, pendingAuthentications == 0 else { return }
        // macOS has just reverted presentationOptions: Cmd+Tab & co. are live
        // until reassertLock() runs.
        Log.lock.notice("Lost active status while locked: re-asserting the lock")
        reassertLock()
    }

    @objc private func otherAppDidActivate(_ notification: Notification) {
        guard isLocked, pendingAuthentications > 0 else { return }
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        guard let app, app != NSRunningApplication.current else { return }
        // System auth agents are background/UI-element processes; a `.regular` app
        // means something (e.g. Cmd+Tab while the panel is up) is escaping the lock.
        let identifier = app.bundleIdentifier ?? app.localizedName ?? "unknown"
        if app.activationPolicy == .regular {
            Log.lock.notice("\(identifier) activated during authentication: taking focus back")
            reassertLock()
        }
        else {
            Log.lock.debug(
                "\(identifier) activated during authentication (policy \(app.activationPolicy.rawValue)): left alone")
        }
    }

    private func reassertLock() {
        NSApp.activate(ignoringOtherApps: true)
        let options: NSApplication.PresentationOptions = [
            .disableProcessSwitching,
            .disableForceQuit,
            .disableSessionTermination,
            .disableHideApplication,
            .disableAppleMenu,
            .hideDock,
            .hideMenuBar,
        ]
        NSApp.presentationOptions = options
        lockWindowController.bringToFront()

        // macOS silently drops options it refuses (or reverts them right away when
        // we are not the active app): compare what actually stuck.
        let applied = NSApp.presentationOptions
        if applied == options {
            Log.lock.debug(
                "Lock re-asserted (presentationOptions 0x\(String(applied.rawValue, radix: 16)), active: \(NSApp.isActive))"
            )
        }
        else {
            Log.lock.error(
                "presentationOptions not fully applied: requested 0x\(String(options.rawValue, radix: 16)), got 0x\(String(applied.rawValue, radix: 16))"
            )
        }
    }

    private func unlockScreen() {
        guard isLocked else { return }
        isLocked = false
        Log.lock.notice("Unlocking")

        systemLockMonitor.disarm()
        authenticator.cancelPendingAuthentications()
        NSApp.presentationOptions = []
        lockWindowController.hide()
        keepAwake.release()
        coordinator.phase = .idle
        Log.lock.notice("Unlocked")
    }

    private func retryAuthentication() {
        guard isLocked else { return }
        coordinator.phase = .authenticating
        pendingAuthentications += 1
        Log.lock.notice("Authentication requested (\(self.pendingAuthentications) prompt(s) in flight)")

        let reason = String(
            localized: "unlock the screen",
            comment:
                "Reason passed to LocalAuthentication; macOS displays it as “ScreenLock is trying to <reason>.”, so it must complete that sentence."
        )
        authenticator.authenticate(reason: reason) { [weak self] outcome in
            guard let self else { return }
            self.pendingAuthentications -= 1
            guard self.isLocked else {
                Log.lock.debug("Authentication result arrived after the unlock: ignored")
                return
            }
            switch outcome {
            case .success:
                self.unlockScreen()
            case .failure(let message):
                Log.lock.notice("Still locked after a failed attempt (\(self.pendingAuthentications) prompt(s) left)")
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
        Log.app.debug("Screen parameters changed: \(NSScreen.screens.count) screen(s), locked: \(self.isLocked)")
        guard isLocked else { return }
        lockWindowController.rebuildForCurrentScreens()
    }
}
