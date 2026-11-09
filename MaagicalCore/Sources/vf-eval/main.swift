import Foundation
import MaagicalCore

// Prompt eval runner: sends every fixture through the smart read brief exactly as the app does
// (same prompt, model, language detection and max tokens) and prints how long each answer is
// and how it starts. Fixtures and runs live in evals/local/, which is gitignored because they
// hold real selections. See evals/README.md.
//
//   cd MaagicalCore && swift run vf-eval [--label name] [--only substring] [--repeat n]
//                                       [--model id] [--fixtures dir] [--prompts dev|prod]

/// Spoken words per second at speed 1.0, about 150 words a minute.
enum Eval { static let wordsPerSecond = 2.5 }

struct Fixture {
    var name: String
    var situation: String
    var aiReply: Bool
    var must: [String]
    var text: String

    /// Header lines `key: value` until a line `---`, then the selected text.
    init(name: String, contents: String) {
        self.name = name
        var situation = "", aiReply = false, must: [String] = []
        var lines = contents.components(separatedBy: "\n")[...]
        if lines.contains("---") {
            while let line = lines.popFirst(), line != "---" {
                let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2 else { continue }
                switch parts[0] {
                case "situation": situation = parts[1]
                case "ai-reply": aiReply = parts[1] == "true"
                case "must": must = parts[1].split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                default: break
                }
            }
        }
        self.situation = situation
        self.aiReply = aiReply
        self.must = must
        self.text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct Result: Codable {
    var fixture: String
    var situation: String
    var inputCharacters: Int
    var words: Int
    var seconds: Double
    var stop: String
    var missing: [String]
    var text: String

    var firstSentence: String {
        let range = text.range(of: #"[.?!](\s|$)"#, options: .regularExpression)
        return range.map { String(text[..<$0.lowerBound]) + String(text[$0.lowerBound]) } ?? text
    }
}

struct Run: Codable {
    var label: String
    var date: Date
    var model: String
    var results: [Result]
}

// MARK: Arguments

func option(_ name: String) -> String? {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
let repoRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
let localDir = repoRoot.appending(path: "evals/local")
let fixturesDir = option("--fixtures").map { URL(filePath: $0) } ?? localDir.appending(path: "fixtures")
let runsDir = localDir.appending(path: "runs")
let label = option("--label") ?? "run"
let only = option("--only")
let repeats = max(1, Int(option("--repeat") ?? "1") ?? 1)
var config = SessionConfiguration()
if let model = option("--model") { config.smartReadModel = model }
// The prompt edits saved in Maagical Dev or the release (Settings > Smart Read > Prompts);
// without the flag, the built-in defaults.
let promptsApp = option("--prompts")
let promptParts: PromptLibrary = switch promptsApp {
case "dev": Preferences.prompts(in: UserDefaults(suiteName: "one.floo.vibeflow.dev") ?? .standard)
case "prod": Preferences.prompts(in: UserDefaults(suiteName: "one.floo.vibeflow") ?? .standard)
default: PromptLibrary()
}

// MARK: API key: ANTHROPIC_API_KEY, else the app's Keychain item (macOS may ask once).

func apiKey() -> String? {
    if let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty { return key }
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/security")
    process.arguments = ["find-generic-password", "-s", "one.floo.vibeflow", "-a", SecretKey.anthropic.rawValue, "-w"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    process.waitUntilExit()
    let key = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return process.terminationStatus == 0 && !key.isEmpty ? key : nil
}

struct StaticSecrets: SecretsStore {
    let key: String
    func read(_ key: SecretKey) -> String? { key == .anthropic ? self.key : nil }
    func write(_ value: String, for key: SecretKey) throws {}
    func delete(_ key: SecretKey) throws {}
    func readOnDemand(_ key: SecretKey) throws -> String? { read(key) }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

// MARK: Run

guard let key = apiKey() else { fail("No Anthropic key: set ANTHROPIC_API_KEY or store one in Maagical.") }
let files = (try? FileManager.default.contentsOfDirectory(at: fixturesDir, includingPropertiesForKeys: nil)) ?? []
let fixtures = files.filter { $0.pathExtension == "txt" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
    .compactMap { url -> Fixture? in
        let name = url.deletingPathExtension().lastPathComponent
        guard only.map({ name.contains($0) }) ?? true, let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Fixture(name: name, contents: contents)
    }
guard !fixtures.isEmpty else { fail("No fixtures in \(fixturesDir.path). See evals/README.md.") }

let client = AnthropicClient(http: URLSessionHTTPClient(), secrets: StaticSecrets(key: key))
let model = config.smartReadModel
let maxTokens = config.maxTokens(for: .brief, inputCharacters: 0)
let promptNote = promptParts.isEdited ? ", your \(promptsApp ?? "") prompt edits" : promptsApp.map { ", no \($0) prompt edits saved" } ?? ""
print("Running \(fixtures.count) fixtures × \(repeats) on \(model)\(promptNote)…\n")

func run(_ fixture: Fixture, client: AnthropicClient, model: String, maxTokens: Int, parts: PromptLibrary) async -> Result {
    let request = SmartReadRequest(text: fixture.text, mode: .brief, language: LanguageDetector.detect(fixture.text),
                                   model: model, maxTokens: maxTokens, assistant: fixture.aiReply ? "Claude" : nil, prompts: parts)
    do {
        let response = try await client.transform(request)
        let words = response.text.split(whereSeparator: \.isWhitespace).count
        let lower = response.text.lowercased()
        return Result(fixture: fixture.name, situation: fixture.situation, inputCharacters: fixture.text.count,
                      words: words, seconds: Double(words) / Eval.wordsPerSecond,
                      stop: response.stopReason == .endTurn ? "end" : "\(response.stopReason)",
                      missing: fixture.must.filter { !lower.contains($0) }, text: response.text)
    } catch {
        return Result(fixture: fixture.name, situation: fixture.situation, inputCharacters: fixture.text.count,
                      words: 0, seconds: 0, stop: "error", missing: fixture.must, text: "\(error)")
    }
}

let jobs = fixtures.flatMap { fixture in Array(repeating: fixture, count: repeats) }
let results: [Result] = await withTaskGroup(of: (Int, Result).self) { group in
    var collected: [(Int, Result)] = []
    var next = 0
    func add(_ group: inout TaskGroup<(Int, Result)>) {
        guard next < jobs.count else { return }
        let index = next, fixture = jobs[index], client = client, model = model, maxTokens = maxTokens, parts = promptParts
        next += 1
        group.addTask { (index, await run(fixture, client: client, model: model, maxTokens: maxTokens, parts: parts)) }
    }
    for _ in 0..<4 { add(&group) }
    while let done = await group.next() {
        collected.append(done)
        add(&group)
    }
    return collected.sorted { $0.0 < $1.0 }.map(\.1)
}

// MARK: Report

/// Each fixture's average words in the newest earlier run that has it, so a run with --only
/// does not blank the comparison for the others.
let previousWords: [String: Int] = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let runs = ((try? FileManager.default.contentsOfDirectory(at: runsDir, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        .compactMap { url in (try? Data(contentsOf: url)).flatMap { try? decoder.decode(Run.self, from: $0) } }
    var words: [String: Int] = [:]
    for run in runs {
        for (fixture, results) in Dictionary(grouping: run.results, by: \.fixture) {
            words[fixture] = results.map(\.words).reduce(0, +) / max(1, results.count)
        }
    }
    return words
}()

func pad(_ s: String, _ n: Int) -> String { s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count) }

print(pad("fixture", 28) + pad("situation", 12) + pad("in", 7) + pad("words ← before", 22) + pad("sec", 6) + "stop  missing")
for r in results {
    let delta = previousWords[r.fixture].map { " ← \($0)" } ?? ""
    print(pad(r.fixture, 28) + pad(r.situation, 12) + pad("\(r.inputCharacters)", 7) + pad("\(r.words)\(delta)", 22)
          + pad(String(format: "%.0f", r.seconds), 6) + pad(r.stop, 6) + r.missing.joined(separator: ", "))
}
let totalSeconds = results.map(\.seconds).reduce(0, +) / Double(results.count)
print(String(format: "\nAverage %.0f words, %.0f s spoken. Must-say misses: %d.\n", Double(results.map(\.words).reduce(0, +)) / Double(results.count),
             totalSeconds, results.filter { !$0.missing.isEmpty }.count))
print("First sentences:")
for r in results { print("  \(pad(r.fixture, 26)) \(r.firstSentence)") }

// Full answers go to the run files, not the terminal.
let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withTime, .withColonSeparatorInTime])
    .replacingOccurrences(of: ":", with: "")
let base = runsDir.appending(path: "\(stamp)-\(label)")
try FileManager.default.createDirectory(at: runsDir, withIntermediateDirectories: true)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
encoder.dateEncodingStrategy = .iso8601
try encoder.encode(Run(label: label, date: Date(), model: model, results: results)).write(to: base.appendingPathExtension("json"))
var markdown = "# \(label), \(model)\n\n"
for r in results {
    markdown += "## \(r.fixture) (\(r.situation), \(r.words) words, \(Int(r.seconds)) s, stop \(r.stop))\n\n"
    if !r.missing.isEmpty { markdown += "Missing: \(r.missing.joined(separator: ", "))\n\n" }
    markdown += r.text + "\n\n"
}
try markdown.write(to: base.appendingPathExtension("md"), atomically: true, encoding: .utf8)
print("\nFull answers: \(base.path).md")
