import AVFoundation
import CoreAudio
import Foundation
import OSLog
import VibeFlowCore

private let log = Logger(subsystem: "one.floo.vibeflow", category: "audio-in")

// MARK: - AudioRecorder on AVAudioEngine

/// Records from one input device into 16 kHz mono 16-bit PCM in memory (perf note P1).
/// A fresh engine per recording: switching the input device of a running engine leaves the
/// input node with a stale format, and this engine never shares a graph with PCMStreamPlayer.
@MainActor
final class LiveAudioRecorder: AudioRecorder {
    private var engine: AVAudioEngine?
    private var sink: PCMSink?

    var permission: MicrophonePermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .undetermined
        default: return .denied
        }
    }

    func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    var isRecording: Bool { engine != nil }

    func start(deviceUID: String?) throws {
        cancel()
        guard permission == .granted else { throw RecordingError.permissionDenied }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let deviceUID {
            if let id = AudioDevices.deviceID(forUID: deviceUID), let unit = input.audioUnit {
                var device = id
                let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                                  &device, UInt32(MemoryLayout<AudioDeviceID>.size))
                if status != noErr { log.error("Could not select input \(deviceUID, privacy: .public): \(status)") }
            } else {
                log.notice("Input \(deviceUID, privacy: .public) not found, using the default input")
            }
        }

        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw RecordingError.noInputDevice }
        guard let sink = PCMSink(inputFormat: format) else { throw RecordingError.engineFailed("unsupported input format") }
        input.installTap(onBus: 0, bufferSize: 4096, format: format, block: Self.tap(into: sink))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw RecordingError.engineFailed(error.localizedDescription)
        }
        self.engine = engine
        self.sink = sink
        log.notice("Recording at \(format.sampleRate, privacy: .public) Hz, \(format.channelCount, privacy: .public) ch")
    }

    func stop() -> RecordedAudio {
        guard let sink else { return .empty }
        tearDown()
        let audio = RecordedAudio(pcm16: sink.data)
        log.notice("Recorded \(audio.pcm16.count / 32, privacy: .public) ms, rms \(audio.rms, privacy: .public)")
        return audio
    }

    func cancel() {
        tearDown()
    }

    private func tearDown() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        sink = nil
    }

    /// Built outside the main actor: the tap runs on the audio thread, and a closure formed in a
    /// main-actor method would trap on its isolation check there.
    nonisolated private static func tap(into sink: PCMSink) -> AVAudioNodeTapBlock {
        { buffer, _ in sink.append(buffer) }
    }
}

/// Converts tap buffers to 16 kHz mono Int16 and accumulates them. Called on the audio thread;
/// `data` is read on the main actor after the tap is removed.
private final class PCMSink: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let lock = NSLock()
    private var buffer = Data()

    init?(inputFormat: AVAudioFormat) {
        guard let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(RecordedAudio.sampleRate), channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inputFormat, to: output) else { return nil }
        converter.downmix = true
        self.converter = converter
        self.outputFormat = output
    }

    var data: Data { lock.withLock { buffer } }

    func append(_ input: AVAudioPCMBuffer) {
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        // The input block runs synchronously inside convert, on this thread; it hands over the
        // one tap buffer, then reports no more data.
        nonisolated(unsafe) var pending: AVAudioPCMBuffer? = input
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            guard let buffer = pending else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            pending = nil
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0, let samples = output.int16ChannelData else { return }
        let chunk = UnsafeBufferPointer(start: samples[0], count: Int(output.frameLength))
        lock.withLock { buffer.append(chunk) }
    }
}

// MARK: - CoreAudio device list

/// Input devices and the default output's transport, for the microphone picker and D7.
enum AudioDevices {
    static func inputs() -> [AudioInputDevice] {
        allDevices().compactMap { id in
            guard inputChannelCount(id) > 0,
                  let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return AudioInputDevice(uid: uid, name: name, transport: transport(id))
        }
    }

    static func defaultOutputIsBluetooth() -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return false }
        return transport(device) == .bluetooth
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        allDevices().first { string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    private static func allDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func transport(_ id: AudioDeviceID) -> AudioInputDevice.Transport {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return .other }
        switch value {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeUSB: return .usb
        default: return .other
        }
    }
}
