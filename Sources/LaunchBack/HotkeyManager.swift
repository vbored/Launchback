import Carbon.HIToolbox
import Foundation

/// Registers one system-wide hotkey via Carbon's `RegisterEventHotKey`.
///
/// This is intentionally *not* a CGEventTap: RegisterEventHotKey needs no
/// Accessibility/Input Monitoring permission, has negligible overhead, and
/// has worked unchanged across every Intel and Apple Silicon macOS release.
/// Default binding is Option+Command+Space; pass a different `keyCode`
/// (from `<Carbon/HIToolbox/Events.h>`, e.g. `kVK_F4` for the old Launchpad
/// key) if you'd rather bind that instead.
final class HotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let onTrigger: () -> Void

    private static let signature: OSType = {
        "LBAK".utf8.reduce(OSType(0)) { ($0 << 8) + OSType($1) }
    }()

    init(
        keyCode: UInt32 = UInt32(kVK_Space),
        modifiers: UInt32 = UInt32(cmdKey | optionKey),
        onTrigger: @escaping () -> Void
    ) {
        self.onTrigger = onTrigger
        register(keyCode: keyCode, modifiers: modifiers)
    }

    private func register(keyCode: UInt32, modifiers: UInt32) {
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )

        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData, let event else { return noErr }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()

                var receivedID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &receivedID
                )

                if receivedID.id == 1 {
                    DispatchQueue.main.async { manager.onTrigger() }
                }
                return noErr
            },
            1,
            &eventType,
            selfPointer,
            &eventHandler
        )

        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
