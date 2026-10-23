# ScreenLock

A macOS app (SwiftUI/AppKit) that lives in the **tray/menu bar** and, on demand, shows a
**non-interactive** full-screen window (on every monitor), prevents app switching
(Cmd+Tab, Force Quit, Dock, menu bar) and keeps the Mac awake (no display/system
sleep). The screen unlocks **only** after a successful Touch ID check; the login
password is asked for **only** when Touch ID is not available.

The app is localized in English (default) and Italian.

## How to trigger it

- **Left-click** the padlock icon in the menu bar → locks the screen immediately.
- **Right-click** the icon → menu with "Lock Now" / "Show Menu Bar Icon" / "Quit".
- **Global shortcut `⌃⌥⌘L`** (Control+Option+Command+L) → locks, or, if already
  locked, **shows the authentication prompt** (the prompt is never shown on its own:
  the same shortcut brings it up the first time and after a cancelled or failed
  attempt).

### Hiding the menu bar icon

"Show Menu Bar Icon" (on by default, persisted in `UserDefaults`) hides the padlock
icon when turned off: the app keeps running and `⌃⌥⌘L` still works. To bring the icon
back, lock with `⌃⌥⌘L` and turn on the **"Show menu bar icon"** switch in the
bottom-left corner of the lock screen. While the icon is hidden there is no "Quit"
menu: turn the icon back on first, or `killall ScreenLock`.

When it locks:
1. A black full-screen window is created for **every connected display**.
2. `NSApp.presentationOptions` is set to disable Cmd+Tab, Force Quit
   (Cmd+Opt+Esc), shut down/restart/log out, Cmd+H, and to hide the Dock and menu bar.
3. A **power assertion** (IOKit) is acquired that prevents system and display sleep,
   plus a "heartbeat" every 20s (`IOPMAssertionDeclareUserActivity`, the same
   technique used by Caffeine/Amphetamine) that resets macOS's real idle timer:
   without it, the *system* screen saver/lock screen would still kick in behind the
   lock window after a few minutes, because it is a timer independent of the
   sleep-prevention assertions. These only block *idle* sleep: closing the laptop
   lid still puts the Mac to sleep (see
   [Known limitations](#known-limitations--possible-future-extensions)).
4. **No authentication prompt is shown yet**: the lock screen just sits there until
   you ask for it with `⌃⌥⌘L`, which starts the Touch ID prompt (or the password
   prompt, if Touch ID is not available — see below). On success, everything is
   restored and the window closes. If it fails or is cancelled, the screen stays
   locked: press `⌃⌥⌘L` again to retry.
5. If another process still manages to activate itself (e.g. `tell application "X" to
   activate` via AppleScript/automation), macOS automatically reverts the
   `presentationOptions` because we are no longer the active app. The app notices
   (`NSApplication.didResignActiveNotification`) and immediately reactivates itself,
   reapplying `presentationOptions` and bringing the window back to the front — see
   ["When the window might lose focus"](#when-the-window-might-lose-focus)
   below for the remaining limitations.
6. If macOS's **own lock screen** appears while ScreenLock is engaged (lid closed,
   sleep, ⌃⌘Q, …), unlocking it with Touch ID or the password also releases
   ScreenLock, so you don't authenticate twice. The app listens for the
   `com.apple.screenIsLocked`/`com.apple.screenIsUnlocked` distributed notifications
   and, since any process can post those, cross-checks each one against the real
   session state (`CGSSessionScreenIsLocked` from `CGSessionCopyCurrentDictionary()`):
   it unlocks only if the system was genuinely locked *after* ScreenLock engaged and
   genuinely is unlocked now. If the system never locks (e.g. "Require password
   after sleep" is off or its delay hasn't elapsed), ScreenLock stays up and asks
   for its own authentication as usual.

On every attempt the app picks the unlock method:
- if Touch ID is usable (`.deviceOwnerAuthenticationWithBiometrics`), **only**
  Touch ID is requested, without a "Use Password…" button;
- otherwise (no sensor, no enrolled fingerprint, laptop lid closed with an external
  monitor, Touch ID locked out after too many attempts, remote session, …) it uses
  `.deviceOwnerAuthentication`, which asks directly for the **login password**
  through the system panel (the app never sees the password).

Before locking, the app checks that at least one of the two methods is **actually
available** on that Mac/session (`canEvaluatePolicy(.deviceOwnerAuthentication)`);
if not, it shows a warning and does **not** engage the lock, precisely to avoid
getting locked out with no way back in.

## ⚠️ Important warning

This app deliberately disables Cmd+Tab, Force Quit and quitting the app while it is
locked: it is nearly impossible to get out without Touch ID or the password. Risks to
be aware of before relying on it as your daily driver:

- **For the first few tests, launch it from Xcode (▶︎), not by double-clicking the
  built `.app`.** Xcode's **Stop (⏹︎ / Cmd+.)** button terminates the process even
  with Cmd+Tab/Force Quit disabled, because it acts from the outside through the
  debugger: it is your safety net while you try out the behavior.
- If something goes wrong while it runs outside Xcode, the recovery options are:
  - SSH from another device and `killall ScreenLock`;
  - Fast User Switching to another administrator account → Activity Monitor/Terminal
    → terminate `ScreenLock`;
  - forced restart (last resort).
- When Touch ID is not available (screen sharing/VNC, external keyboards without a
  sensor, …) unlocking falls back to the password: verify on your hardware that the
  password panel appears above the lock window and receives keyboard input before
  relying on it.

## When the window might lose focus

- **Another app activates itself while we are locked** (AppleScript/automation, an
  app that opens and brings itself to the front on its own, etc.): macOS reverts the
  `presentationOptions` because we are no longer the active app. **Mitigated**: the
  app intercepts `didResignActiveNotification` and immediately reactivates itself,
  reapplying the `presentationOptions` and bringing the window back to the front
  ([AppDelegate.swift](Sources/ScreenLock/AppDelegate.swift)). In the meantime the
  window still stays visually on top of everything, because its level
  (`.screenSaver`) is higher than the Dock/menu bar/normal windows regardless of
  which app is active.
- **While the Touch ID/password panel is open**: the panel belongs to a system
  process, which must become active to receive keyboard input. While an
  authentication is in progress the app does **not** reactivate itself, unless a
  regular app is brought to the front (`activationPolicy == .regular`, e.g. via
  Cmd+Tab): in that case it takes focus back immediately. When the panel closes
  without success, the app reapplies the `presentationOptions`. In the meantime the
  Dock and menu bar may reappear, but they stay below the lock window.
- **Control Center, Notification Center, Siri, Spotlight, Mission Control/hot corners,
  the Cmd+Tab overlay itself**: these are drawn by system processes (not by our app)
  and some are deliberately designed to stay reachable above screen-saver-level
  content. There is no public API for a third-party app to disable them: a complete
  lockdown would require the private Screen Time/Parental Controls frameworks or
  "supervised" mode via MDM.
- **Fast User Switching to another already logged-in account**, **Screen
  Sharing/Apple Remote Desktop** already enabled, or the **physical power button**:
  these bypass this app because they act outside the user session it protects, or at
  a lower level of the operating system.

## Project structure

```
Project.swift                      # Tuist manifest (target, settings, Info.plist)
Tuist.swift                        # Tuist configuration
Makefile                           # install-tuist / generate / build / install
Sources/ScreenLock/
  ScreenLockApp.swift               # @main, no real SwiftUI window (menu bar only)
  AppDelegate.swift                 # status item, global hotkey, lock/unlock orchestration
  LockWindowController.swift        # 1 borderless NSWindow per screen, .screenSaver level
  LockView.swift                    # SwiftUI content of the lock screen
  LockCoordinator.swift             # observable state (idle/authenticating/failed)
  Preferences.swift                 # persisted user preferences (menu bar icon visibility)
  TouchIDAuthenticator.swift        # LocalAuthentication: Touch ID, password only without Touch ID
  PowerAssertion.swift              # IOKit, keeps the Mac awake
  SystemLockMonitor.swift           # releases the lock after a macOS lock screen unlock
  GlobalHotKey.swift                # Carbon Hot Key Manager (no permissions required)
  KeyableWindow.swift               # borderless NSWindow that can become the key window
  Localizable.xcstrings             # String Catalog: English (source) and Italian
```

The app is an **LSUIElement** (no Dock icon) and is **not sandboxed** (required for
IOKit power assertions, Carbon hot keys and `NSApp.presentationOptions`).

## Build & Run

Requires Xcode (`/Applications/Xcode.app`) and [Tuist](https://tuist.dev). The Xcode
project (`ScreenLock.xcodeproj` / `ScreenLock.xcworkspace`) is **generated** from
`Project.swift` and must not be edited by hand.

```bash
make install-tuist   # install Tuist (mise or Homebrew) if missing
make generate        # generate ScreenLock.xcodeproj / .xcworkspace
make build           # Release build into ./build
make install         # build + copy to ~/Applications/ScreenLock.app
```

Other targets: `make edit` (opens the Tuist manifests in Xcode), `make uninstall`,
`make clean`, `make help`.

For development: `make generate && open ScreenLock.xcworkspace`, then the
**ScreenLock** scheme → **Run (▶︎)**. If you change `Project.swift`, run
`make generate` again.

`make install` refuses to proceed if ScreenLock is running: quit it first
(right-click the icon → "Quit").

## Known limitations / possible future extensions

- The window level is `.screenSaver`; with apps in a dedicated full-screen Space
  there may be edge cases that are not fully covered.
- **Closing the lid puts the Mac to sleep** even while locked, unless macOS's own
  clamshell mode is active (power adapter + external display + keyboard/mouse). The
  IOKit assertions used (`PreventUserIdleSystemSleep`/`PreventUserIdleDisplaySleep`)
  only prevent *idle* sleep, and lid-close sleep cannot be blocked by a regular app:
  it would require setting `SleepDisabled` (`pmset -a disablesleep 1`) through a
  privileged root helper. On wake, the system login screen appears (if "Require
  password after sleep" is enabled); unlocking it also releases ScreenLock (see
  step 6 above).
- The system lock/unlock notifications are undocumented (though long-standing and
  widely used); if a future macOS stops posting them, ScreenLock simply falls back
  to asking for its own authentication after the system unlock.
- Mission Control/Hot Corners/Spotlight are not disabled: only Cmd+Tab, Force Quit,
  shut down/log out and Cmd+H, as requested.
- The menu bar icon is the `lock.fill` SF Symbol rather than a custom template
  image (the app icon itself is the `AppIcon` in the asset catalog).

## License

Released under the [MIT License](LICENSE).
