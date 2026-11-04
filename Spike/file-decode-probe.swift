// VibeFlow file transcription T1: can AVAssetReader deliver 16 kHz 16-bit mono PCM directly?
// (docs/designs/file-transcription.md, D4). Tries three readers on one file and reports, for
// each, whether it starts, the format of the first buffer it delivers, frames read and time.
//
//   A  AVAssetReaderTrackOutput, LPCM 16 kHz, 1 channel, 16-bit
//   B  AVAssetReaderTrackOutput, LPCM 16 kHz, 16-bit, no channel key (channels as in the file)
//   C  AVAssetReaderAudioMixOutput, LPCM 16 kHz, 1 channel, 16-bit
//
// Usage: swift Spike/file-decode-probe.swift <audio or video file>
// Reads the file locally; nothing is written or sent.

import AVFoundation
import Foundation

let settingsMono: [String: Any] = [
    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000.0, AVNumberOfChannelsKey: 1,
    AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
    AVLinearPCMIsNonInterleaved: false,
]
var settingsNoChannels = settingsMono
settingsNoChannels.removeValue(forKey: AVNumberOfChannelsKey)

func describe(_ buffer: CMSampleBuffer) -> String {
    guard let desc = CMSampleBufferGetFormatDescription(buffer),
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee else { return "no format" }
    return "\(Int(asbd.mSampleRate)) Hz, \(asbd.mChannelsPerFrame) ch, \(asbd.mBitsPerChannel)-bit"
}

func run(_ label: String, _ make: (AVAsset, AVAssetTrack) throws -> AVAssetReaderOutput, asset: AVAsset, track: AVAssetTrack) {
    let t0 = Date()
    do {
        let reader = try AVAssetReader(asset: asset)
        let output = try make(asset, track)
        guard reader.canAdd(output) else { print("\(label): reader refused the output"); return }
        reader.add(output)
        guard reader.startReading() else { print("\(label): did not start: \(reader.error?.localizedDescription ?? "?")"); return }
        var first: String?
        var frames = 0
        while let buffer = output.copyNextSampleBuffer() {
            if first == nil { first = describe(buffer) }
            frames += CMSampleBufferGetNumSamples(buffer)
        }
        let status = reader.status == .completed ? "completed" : "status \(reader.status.rawValue): \(reader.error?.localizedDescription ?? "")"
        print("\(label): \(status) · first buffer \(first ?? "none") · \(frames) frames · \(String(format: "%.2f", Date().timeIntervalSince(t0))) s")
    } catch {
        print("\(label): FAILED: \(error)")
    }
}

// Output initializers raise Objective-C exceptions for unsupported keys, which Swift cannot
// catch, so each variant runs in its own process: pass A, B or C (default: all three in turn).
let args = CommandLine.arguments
guard args.count == 2 || (args.count == 3 && ["A", "B", "C"].contains(args[2])) else {
    FileHandle.standardError.write(Data("usage: swift Spike/file-decode-probe.swift <file> [A|B|C]\n".utf8)); exit(2)
}
let url = URL(fileURLWithPath: args[1])
let only = args.count == 3 ? args[2] : nil
let asset = AVURLAsset(url: url)
guard let track = try await asset.loadTracks(withMediaType: .audio).first else { print("no audio track"); exit(1) }
let duration = try await asset.load(.duration).seconds
print("File: \(url.lastPathComponent), \(String(format: "%.1f", duration)) s, expected about \(Int(duration * 16_000)) frames at 16 kHz")

if only == nil || only == "A" {
    run("A track output, 1 ch", { _, t in AVAssetReaderTrackOutput(track: t, outputSettings: settingsMono) }, asset: asset, track: track)
}
if only == nil || only == "B" {
    run("B track output, no channel key", { _, t in AVAssetReaderTrackOutput(track: t, outputSettings: settingsNoChannels) }, asset: asset, track: track)
}
if only == nil || only == "C" {
    run("C audio mix output, 1 ch", { _, t in AVAssetReaderAudioMixOutput(audioTracks: [t], audioSettings: settingsMono) }, asset: asset, track: track)
}
