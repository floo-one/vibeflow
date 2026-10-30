import AVFoundation
import CoreAudio
import Foundation

/// The AudioPlayer port on AVAudioEngine (design T8, performance notes P1 and P2).
///
/// - 16-bit mono 24 kHz PCM chunks become Float32 buffers scheduled on an AVAudioPlayerNode.
/// - An AVAudioUnitTimePitch node carries the part of the speed multiplier ElevenLabs cannot
///   (above 1.2), pitch preserved.
/// - Every buffer is scheduled with a `.dataPlayedBack` completion so memory is released
///   and `waitUntilDone` can resolve exactly when the last sample has rendered.
/// - The engine stays warm between reads and stops itself after 60 s idle.
@MainActor
public final class PCMStreamPlayer: AudioPlayer {
    public static let sampleRate = 24_000.0
    public static let idleStopDelay: Duration = .seconds(60)

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let format = AVAudioFormat(standardFormatWithSampleRate: PCMStreamPlayer.sampleRate, channels: 1)!

    /// Buffers scheduled but not yet fully rendered.
    private var pending = 0
    /// Set by `waitUntilDone`: the stream has no more buffers coming.
    private var streamEnded = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var idleStop: Task<Void, Never>?
    /// Bumped by `stop()` so completions from a stopped generation are ignored.
    private var generation = 0

    /// Output device for the next read (Settings > Read > Speaker), nil = system output.
    /// Applied when the engine starts; a change while idle restarts it on the next read.
    public var outputDeviceUID: String? {
        didSet {
            guard outputDeviceUID != oldValue, engine.isRunning, pending == 0 else { return }
            engine.stop()
        }
    }
    /// What the engine's output unit is set to; nil = never touched, follows the system output.
    private var appliedDeviceUID: String?

    public init() {
        engine.attach(node)
        engine.attach(timePitch)
        engine.connect(node, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
    }

    public func prepare() throws {
        idleStop?.cancel()
        if !engine.isRunning {
            applyOutputDevice()
            engine.prepare()
            try engine.start()
        }
    }

    private func applyOutputDevice() {
        guard outputDeviceUID != appliedDeviceUID else { return }
        // Back to the system output: point the unit at the current default device.
        guard let unit = engine.outputNode.audioUnit,
              var device = outputDeviceUID.map(Self.deviceID(forUID:)) ?? Self.defaultOutputDevice() else { return }
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        if status == noErr { appliedDeviceUID = outputDeviceUID }
    }

    private static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafePointer(to: &cfUID) { pointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), pointer, &size, &device)
        }
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    public func schedule(pcm16: Data) {
        let frameCount = AVAudioFrameCount(pcm16.count / 2)
        guard frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount
        let out = buffer.floatChannelData![0]
        pcm16.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<Int(frameCount) {
                out[i] = Float(Int16(littleEndian: samples[i])) / 32768.0
            }
        }
        if !engine.isRunning { try? prepare() }
        pending += 1
        let gen = generation
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.bufferFinished(generation: gen) }
        }
        if !node.isPlaying { node.play() }
    }

    private func bufferFinished(generation gen: Int) {
        guard gen == generation else { return }
        pending = max(0, pending - 1)
        if pending == 0 && streamEnded { resumeWaiters() }
    }

    public func setRate(_ rate: Double) {
        timePitch.rate = Float(min(max(rate, 0.25), 4.0))
    }

    public var playedSeconds: Double {
        guard let nodeTime = node.lastRenderTime, let time = node.playerTime(forNodeTime: nodeTime) else { return 0 }
        return Double(time.sampleTime) / time.sampleRate
    }

    public var isPlaying: Bool { node.isPlaying && pending > 0 }

    public func waitUntilDone() async {
        streamEnded = true
        if pending == 0 { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    public func stop() {
        generation += 1
        node.stop()
        node.reset()
        pending = 0
        streamEnded = false
        resumeWaiters()
        scheduleIdleStop()
    }

    private func resumeWaiters() {
        let w = waiters
        waiters.removeAll()
        streamEnded = false
        w.forEach { $0.resume() }
        scheduleIdleStop()
    }

    /// Perf note P2: keep the engine warm between reads, stop it after a quiet minute.
    private func scheduleIdleStop() {
        idleStop?.cancel()
        idleStop = Task { [weak self] in
            try? await Task.sleep(for: PCMStreamPlayer.idleStopDelay)
            guard let self, !Task.isCancelled, self.pending == 0 else { return }
            self.engine.stop()
        }
    }
}
