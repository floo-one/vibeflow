import Foundation

/// An input device as CoreAudio reports it, for the Settings picker and the Automatic rule.
public struct AudioInputDevice: Sendable, Equatable, Identifiable {
    public enum Transport: Sendable, Equatable {
        case builtIn
        case bluetooth
        case usb
        /// Virtual or aggregate devices (BlackHole, Loom, voice isolation aggregates). They
        /// often deliver silence unless their owning app runs, so Automatic never picks them.
        case virtual
        case other
    }

    public let uid: String
    public let name: String
    public let transport: Transport
    public var id: String { uid }

    public init(uid: String, name: String, transport: Transport) {
        self.uid = uid
        self.name = name
        self.transport = transport
    }
}

/// Which microphone a dictation records from (D7).
///
/// Opening a Bluetooth headset's microphone switches it to the call profile, so every read
/// afterwards sounds like a phone line. Automatic therefore uses the built-in microphone
/// while the output is Bluetooth. It also skips a virtual or aggregate system default input
/// (verified 2026-10-06: a "voice isolation aggregate" default recorded pure silence).
/// Otherwise it uses the system default input. A chosen device that is unplugged falls back
/// to Automatic.
public enum MicrophoneSelection {
    /// `choice` nil = Automatic. Returns the device UID to record from, nil = system default input.
    public static func deviceUID(choice: String?, inputs: [AudioInputDevice], outputIsBluetooth: Bool, defaultInputUID: String?) -> String? {
        if let choice, inputs.contains(where: { $0.uid == choice }) { return choice }
        let builtIn = inputs.first(where: { $0.transport == .builtIn })?.uid
        if outputIsBluetooth, let builtIn { return builtIn }
        let defaultInput = inputs.first(where: { $0.uid == defaultInputUID })
        if defaultInput == nil || defaultInput?.transport == .virtual {
            return builtIn ?? inputs.first(where: { $0.transport != .virtual })?.uid
        }
        return nil
    }
}
