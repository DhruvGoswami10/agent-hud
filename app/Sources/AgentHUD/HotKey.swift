import AppKit
import Carbon.HIToolbox

/// One global hot key that retracts the HUD from wherever you are.
///
/// Registered through Carbon's RegisterEventHotKey rather than an NSEvent
/// global monitor on purpose: a keyboard monitor would see every keystroke
/// you type and needs the Accessibility permission, while a registered hot
/// key sees exactly one chord and needs no permission at all.
@MainActor
final class HotKey {
    static let shared = HotKey()

    /// ⌥⎋ — free on stock macOS and reachable without moving your hand.
    static let keyCode = UInt32(kVK_Escape)
    static let modifiers = UInt32(optionKey)
    static let displayName = "⌥⎋"

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private(set) var enabled = false

    func enable(_ fire: @escaping () -> Void) {
        disable()
        hotKeyFire = fire

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return noErr }
            var id = EventHotKeyID()
            let ok = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                       EventParamType(typeEventHotKeyID), nil,
                                       MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard ok == noErr, id.signature == hotKeySignature else { return noErr }
            DispatchQueue.main.async { hotKeyFire?() }
            return noErr
        }, 1, &spec, nil, &eventHandler)
        guard installed == noErr else {
            NSLog("AgentHUD: hot key handler install failed (\(installed))")
            return
        }

        let id = EventHotKeyID(signature: hotKeySignature, id: 1)
        let status = RegisterEventHotKey(Self.keyCode, Self.modifiers, id,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status == noErr {
            enabled = true
        } else {
            // Another app owns the chord. Not fatal — everything else still
            // dismisses; say so rather than pretending it took.
            NSLog("AgentHUD: could not register \(Self.displayName) (\(status)); another app may own it")
            disable()
        }
    }

    func disable() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        hotKeyRef = nil
        if let handler = eventHandler { RemoveEventHandler(handler) }
        eventHandler = nil
        hotKeyFire = nil
        enabled = false
    }
}

/// The Carbon callback is a C function pointer and cannot capture context,
/// so the action lives here. Only ever written on the main thread.
private let hotKeySignature: OSType = 0x41474844  // 'AGHD'
nonisolated(unsafe) private var hotKeyFire: (() -> Void)?
