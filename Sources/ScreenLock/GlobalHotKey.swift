//
//  GlobalHotKey.swift
//  ScreenLock
//
//  Created by Federico Gasperini on 22/10/26.
//

import Carbon.HIToolbox
import AppKit

/// Registers a single systemwide keyboard shortcut using the (permission-free)
/// Carbon Hot Key Manager, so no Accessibility/Input Monitoring grant is needed.
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let callback: () -> Void
    private let hotKeyID = EventHotKeyID(signature: OSType(0x534C_4B31), id: 1) // 'SLK1'

    init?(keyCode: UInt32, modifiers: UInt32, callback: @escaping () -> Void) {
        self.callback = callback

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData -> OSStatus in
                guard let userData, let eventRef else { return noErr }
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                let instance = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                if hotKeyID.id == instance.hotKeyID.id {
                    Log.hotkey.debug("Hotkey pressed")
                    instance.callback()
                }
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &eventHandlerRef
        )

        guard installStatus == noErr else {
            Log.hotkey.error("InstallEventHandler failed: status \(describe(status: installStatus))")
            return nil
        }

        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard registerStatus == noErr else {
            // -9878 (eventHotKeyExistsErr) means another process already owns the
            // combination: the shortcut will simply never fire for us.
            Log.hotkey.error("RegisterEventHotKey failed for keyCode \(keyCode) modifiers \(modifiers): status \(describe(status: registerStatus))")
            if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
            return nil
        }

        Log.hotkey.notice("Global hotkey registered (keyCode \(keyCode), modifiers \(modifiers))")
    }

    deinit {
        Log.hotkey.notice("Unregistering global hotkey")
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
    }
}
