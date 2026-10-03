// VibeFlow 2 T1 follow-up: does Apple's on-device SpeechTranscriber work on this Mac,
// is the language model installed, and does it need a separate permission?
//   swift Spike/apple-stt-probe.swift path/to/16k-mono.wav [locale]
import AVFoundation
import Foundation
import Speech

@available(macOS 26.0, *)
func run(_ path: String, _ localeID: String) async -> Int32 {
    guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeID)) else {
        print("unsupported locale \(localeID)"); return 1
    }
    let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
    let status = await AssetInventory.status(forModules: [transcriber])
    print("locale \(locale.identifier), model status: \(status)")
    if status != .installed {
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                let t0 = Date()
                print("downloading model...")
                try await request.downloadAndInstall()
                print(String(format: "installed in %.1f s", Date().timeIntervalSince(t0)))
            }
        } catch { print("install failed: \(error)"); return 1 }
    }
    do {
        let t0 = Date()
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        async let text: String = {
            var s = ""
            for try await r in transcriber.results where r.isFinal { s += String(r.text.characters) }
            return s
        }()
        if let end = try await analyzer.analyzeSequence(from: file) { try await analyzer.finalizeAndFinish(through: end) }
        else { await analyzer.cancelAndFinishNow() }
        let result = try await text
        print(String(format: "transcribed in %.0f ms: %@", Date().timeIntervalSince(t0) * 1000, result))
        return 0
    } catch { print("transcription failed: \(error)"); return 1 }
}

let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: apple-stt-probe.swift file.wav [locale]"); exit(2) }
if #available(macOS 26.0, *) { exit(await run(args[1], args.count > 2 ? args[2] : "en-US")) }
else { print("needs macOS 26"); exit(1) }
