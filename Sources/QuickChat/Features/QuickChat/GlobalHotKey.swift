import Carbon.HIToolbox

/// A system-wide hotkey registered with Carbon's `RegisterEventHotKey` (the same mechanism
/// ChatGPT's Electron `globalShortcut` uses). Call `unregister()` to release it.
@MainActor
final class GlobalHotKey {
    private static var handlers: [UInt32: @MainActor () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var eventHandler: EventHandlerRef?

    private var ref: EventHotKeyRef?
    private let id: UInt32

    /// Registers `shortcut`; throws if the system refuses it.
    init(_ shortcut: Shortcut, handler: @escaping @MainActor () -> Void) throws {
        Self.installEventHandlerIfNeeded()
        id = Self.nextID
        Self.nextID += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x4350_4C53) /* 'CPLS' */, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            throw FeatureError("Couldn't register the shortcut \(shortcut.displayString) (error \(status)).",
                               recoverySuggestion: "Another app may be using it. Choose a different shortcut.")
        }
        self.ref = ref
        Self.handlers[id] = handler
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        Self.handlers[id] = nil
    }

    private static func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let id = hotKeyID.id
            // Carbon delivers hotkey events on the main thread.
            MainActor.assumeIsolated { GlobalHotKey.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }
}
