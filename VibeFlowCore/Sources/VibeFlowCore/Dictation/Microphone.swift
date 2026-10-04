import Foundation

/// An input device as CoreAudio reports it, for the Settings picker and the Automatic rule.
public struct AudioInputDevice: Sendable, Equatable, Identifiable {
    public enum Transport: Sendable, Equatable {
        case builtIn
        case bluetooth
        case usb
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
/// while the output is Bluetooth, and the system default input otherwise. A chosen device
/// that is unplugged falls back to Automatic.
public enum MicrophoneSelection {
    /// `choice` nil = Automatic. Returns the device UID to record from, nil = system default input.
    public static func deviceUID(choice: String?, inputs: [AudioInputDevice], outputIsBluetooth: Bool) -> String? {
        if let choice, inputs.contains(where: { $0.uid == choice }) { return choice }
        if outputIsBluetooth, let builtIn = inputs.first(where: { $0.transport == .builtIn }) { return builtIn.uid }
        return nil
    }
}
