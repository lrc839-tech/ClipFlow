import AppKit
import Carbon

public struct HotKeyRegistration: Codable {
    public let slot: Int
    public let label: String
    public let keyCode: UInt32
    public let status: Int32
    public var registered: Bool { status == noErr }
}

/// Carbon registration does not observe arbitrary typing and does not require an event tap.
/// Key positions refer to the ANSI number row, independent of the current input source.
public final class HotKeyService {
    public static let keyCodes: [UInt32] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29, 27, 24]
    public static let labels = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "="]
    private let signature: OSType = 0x434C4657 // CLFW
    private var handler: EventHandlerRef?
    private var references: [EventHotKeyRef] = []
    public var onPress: ((Int) -> Void)?

    public init() {}

    public func register(scheme: HotKeyScheme = .option) -> [HotKeyRegistration] {
        precondition(Thread.isMainThread)
        unregister()
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            let service = Unmanaged<HotKeyService>.fromOpaque(context).takeUnretainedValue()
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                          EventParamType(typeEventHotKeyID), nil,
                                          MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == service.signature, (1...12).contains(Int(id.id)) else {
                return OSStatus(eventNotHandledErr)
            }
            service.onPress?(Int(id.id))
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)

        return Self.keyCodes.enumerated().map { index, code in
            var reference: EventHotKeyRef?
            let status = installed == noErr
                ? RegisterEventHotKey(code, scheme.carbonModifiers,
                                      EventHotKeyID(signature: signature, id: UInt32(index + 1)),
                                      GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference)
                : installed
            if let reference, status == noErr { references.append(reference) }
            return HotKeyRegistration(slot: index + 1, label: "\(scheme.name)+\(Self.labels[index])", keyCode: code, status: status)
        }
    }

    public func unregister() {
        precondition(Thread.isMainThread)
        references.forEach { UnregisterEventHotKey($0) }
        references.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    /// Use only while no service owns the key. Does not displace an existing registration.
    public static func conflictExperiment() -> [String: Int32] {
        precondition(Thread.isMainThread)
        var first: EventHotKeyRef?
        var second: EventHotKeyRef?
        let one = RegisterEventHotKey(keyCodes[0], UInt32(optionKey),
                                     EventHotKeyID(signature: 0x54455354, id: 101),
                                     GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &first)
        let two = RegisterEventHotKey(keyCodes[0], UInt32(optionKey),
                                     EventHotKeyID(signature: 0x54455354, id: 102),
                                     GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &second)
        if let second { UnregisterEventHotKey(second) }
        if let first { UnregisterEventHotKey(first) }
        return ["firstStatus": one, "secondStatus": two]
    }
}
