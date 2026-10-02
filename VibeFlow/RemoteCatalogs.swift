import Foundation
import Observation
import VibeFlowCore

struct ElevenLabsVoice: Identifiable, Hashable {
    let id: String
    let name: String
    let description: String
}

struct AnthropicModel: Identifiable, Hashable {
    let id: String
    let name: String
}

enum CatalogState: Equatable {
    case noKey
    case loading
    case loaded
    /// The list endpoint is not allowed for this key; `voices` holds built-in fallbacks.
    case limited(String)
    case failed(String)
}

/// Reads the human message out of an API error body ({"detail":{"message":...}} for
/// ElevenLabs, {"error":{"message":...}} for Anthropic).
struct APIErrorBody: Decodable {
    struct Detail: Decodable { let message: String?; let status: String? }
    let detail: Detail?
    let error: Detail?

    static func parse(_ data: Data) -> (message: String?, status: String?) {
        guard let body = try? JSONDecoder().decode(APIErrorBody.self, from: data) else { return (nil, nil) }
        let d = body.detail ?? body.error
        return (d?.message, d?.status)
    }
}

/// Voice and model lists fetched with the stored keys, for the settings pickers.
/// Refreshed at launch and whenever keys are saved.
@MainActor
@Observable
final class RemoteCatalogs {
    private(set) var voices: [ElevenLabsVoice] = []
    private(set) var voicesState: CatalogState = .noKey
    private(set) var models: [AnthropicModel] = []
    private(set) var modelsState: CatalogState = .noKey

    private let secrets: KeychainSecretsStore

    init(secrets: KeychainSecretsStore) {
        self.secrets = secrets
    }

    func refresh() {
        refreshVoices()
        refreshModels()
    }

    func refreshVoices() {
        guard let key = secrets.read(.elevenLabs) else {
            voices = []
            voicesState = .noKey
            return
        }
        voicesState = .loading
        Task {
            do {
                var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/voices")!)
                request.setValue(key, forHTTPHeaderField: "xi-api-key")
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                guard status == 200 else {
                    let (message, code) = APIErrorBody.parse(data)
                    if code == "missing_permissions" {
                        // Key can speak but not list voices: offer the premade voices and a custom id.
                        voices = Self.premadeVoices
                        voicesState = .limited("This key can read aloud but can't list your voices. In ElevenLabs, edit the key and enable Voices: Read to see your full library.")
                    } else if status == 401 {
                        voicesState = .failed(message ?? "ElevenLabs rejected the key")
                    } else {
                        voicesState = .failed(message ?? "ElevenLabs returned HTTP \(status)")
                    }
                    return
                }
                let decoded = try JSONDecoder().decode(VoicesResponse.self, from: data)
                voices = decoded.voices.map {
                    let labels = ($0.labels ?? [:]).values.sorted().joined(separator: ", ")
                    return ElevenLabsVoice(id: $0.voice_id, name: $0.name, description: labels)
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                voicesState = .loaded
            } catch {
                voicesState = .failed(error.localizedDescription)
            }
        }
    }

    func refreshModels() {
        guard let key = secrets.read(.anthropic) else {
            models = []
            modelsState = .noKey
            return
        }
        modelsState = .loading
        Task {
            do {
                var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=100")!)
                request.setValue(key, forHTTPHeaderField: "x-api-key")
                request.setValue(AnthropicClient.apiVersion, forHTTPHeaderField: "anthropic-version")
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                guard status == 200 else {
                    let (message, _) = APIErrorBody.parse(data)
                    modelsState = .failed(message ?? (status == 401 ? "Anthropic rejected the key" : "Anthropic returned HTTP \(status)"))
                    return
                }
                let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
                models = decoded.data.map { AnthropicModel(id: $0.id, name: $0.display_name ?? $0.id) }
                modelsState = .loaded
            } catch {
                modelsState = .failed(error.localizedDescription)
            }
        }
    }

    /// ElevenLabs premade voices, shown when the key cannot list the library.
    static let premadeVoices = [
        ElevenLabsVoice(id: "JBFqnCBsd6RMkjVDRZzb", name: "George", description: "male, narrative"),
        ElevenLabsVoice(id: "EXAVITQu4vr4xnSDxMaL", name: "Sarah", description: "female, soft"),
        ElevenLabsVoice(id: "onwK4e9ZLuTAKqWW03F9", name: "Daniel", description: "male, authoritative"),
        ElevenLabsVoice(id: "XB0fDUnXU5powFXDhCwa", name: "Charlotte", description: "female, conversational"),
    ]

    private struct VoicesResponse: Decodable {
        struct Voice: Decodable {
            let voice_id: String
            let name: String
            let labels: [String: String]?
        }
        let voices: [Voice]
    }

    private struct ModelsResponse: Decodable {
        struct Model: Decodable {
            let id: String
            let display_name: String?
        }
        let data: [Model]
    }
}
