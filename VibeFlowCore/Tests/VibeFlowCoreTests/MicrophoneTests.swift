import Testing
@testable import VibeFlowCore

@Suite("Microphone selection (D7)")
struct MicrophoneTests {
    let builtIn = AudioDevice(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", transport: .builtIn)
    let airPods = AudioDevice(uid: "AA-BB-CC:input", name: "AirPods Pro", transport: .bluetooth)
    let usb = AudioDevice(uid: "usb-podcast-mic", name: "Shure MV7", transport: .usb)

    @Test func automaticUsesTheBuiltInMicWhileListeningOnBluetooth() {
        #expect(MicrophoneSelection.deviceUID(choice: nil, inputs: [airPods, builtIn], outputIsBluetooth: true, defaultInputUID: airPods.uid) == builtIn.uid)
    }

    @Test func automaticUsesTheSystemDefaultOtherwise() {
        #expect(MicrophoneSelection.deviceUID(choice: nil, inputs: [airPods, builtIn, usb], outputIsBluetooth: false, defaultInputUID: builtIn.uid) == nil)
    }

    @Test func automaticWithoutABuiltInMicUsesTheSystemDefault() {
        // A Mac mini or a closed-lid MacBook has no built-in input to switch to.
        #expect(MicrophoneSelection.deviceUID(choice: nil, inputs: [airPods, usb], outputIsBluetooth: true, defaultInputUID: airPods.uid) == nil)
    }

    @Test func aChosenDeviceWinsEvenOnBluetooth() {
        #expect(MicrophoneSelection.deviceUID(choice: usb.uid, inputs: [airPods, builtIn, usb], outputIsBluetooth: true, defaultInputUID: airPods.uid) == usb.uid)
        #expect(MicrophoneSelection.deviceUID(choice: airPods.uid, inputs: [airPods, builtIn], outputIsBluetooth: true, defaultInputUID: airPods.uid) == airPods.uid)
    }

    @Test func anUnpluggedChoiceFallsBackToAutomatic() {
        #expect(MicrophoneSelection.deviceUID(choice: usb.uid, inputs: [airPods, builtIn], outputIsBluetooth: true, defaultInputUID: airPods.uid) == builtIn.uid)
        #expect(MicrophoneSelection.deviceUID(choice: usb.uid, inputs: [builtIn], outputIsBluetooth: false, defaultInputUID: builtIn.uid) == nil)
    }

    let aggregate = AudioDevice(uid: "~:AMS2_Aggregate:0", name: "voice isolation aggregate", transport: .virtual)
    let blackHole = AudioDevice(uid: "BlackHole2ch_UID", name: "BlackHole 2ch", transport: .virtual)

    @Test func automaticSkipsAVirtualDefaultInput() {
        let inputs = [aggregate, blackHole, builtIn, usb]
        #expect(MicrophoneSelection.deviceUID(choice: nil, inputs: inputs, outputIsBluetooth: false, defaultInputUID: aggregate.uid) == builtIn.uid)
        #expect(MicrophoneSelection.deviceUID(choice: nil, inputs: [aggregate, usb], outputIsBluetooth: false, defaultInputUID: aggregate.uid) == usb.uid)
    }

    @Test func automaticKeepsARealDefaultInput() {
        #expect(MicrophoneSelection.deviceUID(choice: nil, inputs: [aggregate, builtIn, usb], outputIsBluetooth: false, defaultInputUID: usb.uid) == nil)
    }

    @Test func aVirtualDeviceCanStillBeChosenOnPurpose() {
        #expect(MicrophoneSelection.deviceUID(choice: blackHole.uid, inputs: [blackHole, builtIn], outputIsBluetooth: false, defaultInputUID: builtIn.uid) == blackHole.uid)
    }
}
