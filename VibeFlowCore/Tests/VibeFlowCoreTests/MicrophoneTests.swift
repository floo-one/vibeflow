import Testing
@testable import VibeFlowCore

@Suite("Microphone selection (D7)")
struct MicrophoneTests {
    let builtIn = AudioInputDevice(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", transport: .builtIn)
    let airPods = AudioInputDevice(uid: "AA-BB-CC:input", name: "AirPods Pro", transport: .bluetooth)
    let usb = AudioInputDevice(uid: "usb-podcast-mic", name: "Shure MV7", transport: .usb)

    @Test func automaticUsesTheBuiltInMicWhileListeningOnBluetooth() {
        #expect(MicrophoneSelection.deviceUID(choice: nil, inputs: [airPods, builtIn], outputIsBluetooth: true) == builtIn.uid)
    }

    @Test func automaticUsesTheSystemDefaultOtherwise() {
        #expect(MicrophoneSelection.deviceUID(choice: nil, inputs: [airPods, builtIn, usb], outputIsBluetooth: false) == nil)
    }

    @Test func automaticWithoutABuiltInMicUsesTheSystemDefault() {
        // A Mac mini or a closed-lid MacBook has no built-in input to switch to.
        #expect(MicrophoneSelection.deviceUID(choice: nil, inputs: [airPods, usb], outputIsBluetooth: true) == nil)
    }

    @Test func aChosenDeviceWinsEvenOnBluetooth() {
        #expect(MicrophoneSelection.deviceUID(choice: usb.uid, inputs: [airPods, builtIn, usb], outputIsBluetooth: true) == usb.uid)
        #expect(MicrophoneSelection.deviceUID(choice: airPods.uid, inputs: [airPods, builtIn], outputIsBluetooth: true) == airPods.uid)
    }

    @Test func anUnpluggedChoiceFallsBackToAutomatic() {
        #expect(MicrophoneSelection.deviceUID(choice: usb.uid, inputs: [airPods, builtIn], outputIsBluetooth: true) == builtIn.uid)
        #expect(MicrophoneSelection.deviceUID(choice: usb.uid, inputs: [builtIn], outputIsBluetooth: false) == nil)
    }
}
