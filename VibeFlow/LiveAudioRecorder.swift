import AVFoundation
import CoreAudio
import Foundation
import OSLog
import VibeFlowCore

private let log = Logger(subsystem: "one.floo.vibeflow", category: "audio-in")

// MARK: - AudioRecorder on AVCaptureSession

/// Records one input device into 16 kHz mono 16-bit PCM in memory (perf note P1).
///
/// AVCaptureSession, not AVAudioEngine: verified 2026-10-06, opening the microphone made
/// CoreAudio reconfigure the I/O unit, and AVAudioEngine stops itself on that configuration
/// change, so every recording came back as digital silence. A capture session only touches
/// the input and converts to the target format itself.
@MainActor
final class LiveAudioRecorder: AudioRecorder {
    private var recording: CaptureRecording?

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

    var isRecording: Bool { recording != nil }

    /// Loudness of the latest buffer, 0 (silence) to 1, for the notch waveform.
    var level: Float { recording?.level ?? 0 }

    func start(deviceUID: String?, onReady: @escaping @MainActor @Sendable () -> Void) throws {
        cancel()
        guard permission == .granted else { throw RecordingError.permissionDenied }
        let chosen = deviceUID.flatMap { AVCaptureDevice(uniqueID: $0) }
        if deviceUID != nil && chosen == nil {
            log.notice("Input \(deviceUID ?? "", privacy: .public) not found, using the default input")
        }
        guard let device = chosen ?? AVCaptureDevice.default(for: .audio) else { throw RecordingError.noInputDevice }
        let recording = try CaptureRecording(device: device, onFirstBuffer: { Task { @MainActor in onReady() } })
        recording.start()
        self.recording = recording
        log.notice("Recording from \(device.localizedName, privacy: .public) (\(device.uniqueID, privacy: .public))")
    }

    func stop() -> RecordedAudio {
        guard let recording else { return .empty }
        self.recording = nil
        let audio = RecordedAudio(pcm16: recording.finish())
        log.notice("Recorded \(audio.pcm16.count / 32, privacy: .public) ms, rms \(audio.rms, privacy: .public)")
        return audio
    }

    func cancel() {
        _ = recording?.finish()
        recording = nil
    }
}

/// One capture session. Sample buffers arrive on `sampleQueue`; starting and stopping the
/// session block, so they run on `sessionQueue`, never on the main thread.
private final class CaptureRecording: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "one.floo.vibeflow.audio-in.session")
    private let sampleQueue = DispatchQueue(label: "one.floo.vibeflow.audio-in.samples")
    private let lock = NSLock()
    private var pcm = Data()
    private var finished = false
    private var latestLevel: Float = 0
    /// Called once, on the sample queue, when the first audio arrives.
    private var onFirstBuffer: (@Sendable () -> Void)?

    var level: Float { lock.withLock { latestLevel } }

    init(device: AVCaptureDevice, onFirstBuffer: @escaping @Sendable () -> Void) throws {
        self.onFirstBuffer = onFirstBuffer
        super.init()
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw RecordingError.engineFailed(error.localizedDescription)
        }
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Double(RecordedAudio.sampleRate),
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw RecordingError.engineFailed("the microphone cannot be opened")
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        output.setSampleBufferDelegate(self, queue: sampleQueue)
    }

    func start() {
        sessionQueue.async { [session] in session.startRunning() }
    }

    /// Returns everything captured so far and stops the session in the background.
    func finish() -> Data {
        let data: Data = lock.withLock {
            finished = true
            return pcm
        }
        sessionQueue.async { [session] in session.stopRunning() }
        return data
    }

    /// RMS of 16-bit samples on a -50 to -10 dBFS scale, so speech fills the range.
    private static func level(of chunk: Data) -> Float {
        let sumOfSquares: Float = chunk.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).reduce(0) { sum, sample in
                let x = Float(sample) / Float(Int16.max)
                return sum + x * x
            }
        }
        let count = chunk.count / MemoryLayout<Int16>.size
        guard count > 0, sumOfSquares > 0 else { return 0 }
        let decibels = 10 * log10(sumOfSquares / Float(count))
        return min(max((decibels + 50) / 40, 0), 1)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return }
        var chunk = Data(count: length)
        let status = chunk.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        guard status == kCMBlockBufferNoErr else { return }
        let level = Self.level(of: chunk)
        let first: (@Sendable () -> Void)? = lock.withLock {
            guard !finished else { return nil }
            pcm.append(chunk)
            latestLevel = level
            defer { onFirstBuffer = nil }
            return onFirstBuffer
        }
        first?()
    }
}

// MARK: - CoreAudio device list

/// Input and output devices and the default devices, for the Settings pickers and D7.
enum AudioDevices {
    static func inputs() -> [AudioDevice] { devices(scope: kAudioDevicePropertyScopeInput) }

    static func outputs() -> [AudioDevice] { devices(scope: kAudioDevicePropertyScopeOutput) }

    private static func devices(scope: AudioObjectPropertyScope) -> [AudioDevice] {
        allDevices().compactMap { id in
            guard channelCount(id, scope: scope) > 0,
                  let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return AudioDevice(uid: uid, name: name, transport: transport(id))
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

    static func defaultInputUID() -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }
        return string(device, kAudioDevicePropertyDeviceUID)
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

    private static func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: scope, mElement: kAudioObjectPropertyElementMain)
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

    private static func transport(_ id: AudioDeviceID) -> AudioDevice.Transport {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return .other }
        switch value {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: return .virtual
        default: return .other
        }
    }
}
