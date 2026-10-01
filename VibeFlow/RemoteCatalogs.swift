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
    case failed(String)
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
                    voicesState = .failed(status == 401 ? "ElevenLabs rejected the key" : "ElevenLabs returned HTTP \(status)")
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
                    modelsState = .failed(status == 401 ? "Anthropic rejected the key" : "Anthropic returned HTTP \(status)")
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
