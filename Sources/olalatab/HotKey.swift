import Carbon

/// ⌥⇥ and ⌥⇧⇥ as Carbon global hot keys: the WindowServer matches them, so olalatab gets no
/// event at all for ordinary typing and costs nothing at rest.
final class HotKey {
    /// `backwards` is true for ⌥⇧⇥; `eventTime` is when the key was pressed (nanoseconds since boot).
    typealias Handler = (_ backwards: Bool, _ eventTime: UInt64) -> Void

    private let handler: Handler
    private var refs: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?
    private static let signature: OSType = 0x4F4C_4154 // 'OLAT'

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Returns false when ⌥⇥ is already registered by another app (or another olalatab).
    func register() -> Bool {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            hotKey.handler(id.id == 2, Clock.nanos(eventTime: GetEventTime(event)))
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)

        for (id, modifiers) in [(UInt32(1), optionKey), (UInt32(2), optionKey | shiftKey)] {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(kVK_Tab), UInt32(modifiers),
                                             EventHotKeyID(signature: Self.signature, id: id),
                                             GetApplicationEventTarget(), 0, &ref)
            guard status == noErr, let ref else {
                if id == 1 { return false }
                log("⌥⇧⇥ unavailable (status \(status)): ⇧Tab still works once the switcher is open.")
                continue
            }
            refs.append(ref)
        }
        return true
    }
}
