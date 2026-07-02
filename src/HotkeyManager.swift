import AppKit
import Carbon.HIToolbox

/// Global hotkeys via Carbon RegisterEventHotKey — works without the
/// Accessibility permission, unlike NSEvent global monitors.
@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    private var hotkeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1
    private var eventHandlerInstalled = false

    private init() {}

    func registerAll(dispatch: @escaping (HotkeyAction) -> Void) {
        unregisterAll()
        for action in HotkeyAction.allCases {
            guard let hotkey = Settings.shared.hotkey(for: action) else { continue }
            register(hotkey) { dispatch(action) }
        }
    }

    func unregisterAll() {
        for (_, ref) in hotkeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotkeyRefs.removeAll()
        handlers.removeAll()
    }

    private func register(_ hotkey: Hotkey, handler: @escaping () -> Void) {
        installEventHandlerIfNeeded()

        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotkeyID = EventHotKeyID(signature: OSType(0x53_43_41_50) /* "SCAP" */, id: id)
        let status = RegisterEventHotKey(
            hotkey.keyCode,
            hotkey.carbonModifiers,
            hotkeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            NSLog("hotkey registration failed for \(hotkey.display): \(status)")
            return
        }
        hotkeyRefs[id] = ref
        handlers[id] = handler
    }

    private func installEventHandlerIfNeeded() {
        guard !eventHandlerInstalled else { return }
        eventHandlerInstalled = true

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, _ -> OSStatus in
                var hotkeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotkeyID
                )
                // Carbon dispatches on the main thread's event loop.
                DispatchQueue.main.async {
                    HotkeyManager.shared.handlers[hotkeyID.id]?()
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            nil
        )
    }
}

extension NSEvent.ModifierFlags {
    var carbonModifiers: UInt32 {
        var mods: UInt32 = 0
        if contains(.command) { mods |= UInt32(cmdKey) }
        if contains(.option) { mods |= UInt32(optionKey) }
        if contains(.shift) { mods |= UInt32(shiftKey) }
        if contains(.control) { mods |= UInt32(controlKey) }
        return mods
    }
}
