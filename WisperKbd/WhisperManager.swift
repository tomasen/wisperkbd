import Foundation
import WhisperKit

/// Current state of the WhisperKit engine.
enum WhisperState {
    case notLoaded
    case downloading
    case loading
    case ready
    case failed(Error)

    var displayText: String {
        switch self {
        case .notLoaded: return "Model not loaded"
        case .downloading: return "Downloading model..."
        case .loading: return "Loading model..."
        case .ready: return "Ready"
        case .failed(let error): return "Error: \(error.localizedDescription)"
        }
    }

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// Available Whisper models.
enum WhisperModel: String, CaseIterable {
    case tiny = "openai_whisper-tiny"
    case base = "openai_whisper-base"
    case small = "openai_whisper-small"
    case large = "openai_whisper-large-v3-v20240930"

    var displayName: String {
        switch self {
        case .tiny: return "Tiny (~75 MB)"
        case .base: return "Base (~140 MB)"
        case .small: return "Small (~460 MB)"
        case .large: return "Large (~3 GB)"
        }
    }
}

/// Supported languages for transcription.
struct WhisperLanguage {
    let code: String?   // nil = auto-detect
    let name: String

    static let supported: [WhisperLanguage] = [
        WhisperLanguage(code: nil, name: "Auto-detect"),
        WhisperLanguage(code: "en", name: "English"),
        WhisperLanguage(code: "zh", name: "Chinese"),
        WhisperLanguage(code: "ja", name: "Japanese"),
        WhisperLanguage(code: "ko", name: "Korean"),
        WhisperLanguage(code: "de", name: "German"),
        WhisperLanguage(code: "fr", name: "French"),
        WhisperLanguage(code: "es", name: "Spanish"),
        WhisperLanguage(code: "pt", name: "Portuguese"),
        WhisperLanguage(code: "ru", name: "Russian"),
        WhisperLanguage(code: "ar", name: "Arabic"),
        WhisperLanguage(code: "it", name: "Italian"),
    ]
}

/// Manages WhisperKit pipeline for speech-to-text transcription.
class WhisperManager {
    static let shared = WhisperManager()

    private var whisperKit: WhisperKit?
    private let initLock = NSLock()

    private static let modelKey = "WisperKbd_SelectedModel"
    private static let languageKey = "WisperKbd_SelectedLanguage"

    /// Observable state for UI
    private(set) var state: WhisperState = .notLoaded {
        didSet {
            NSLog("WisperKbd: WhisperManager state -> \(state.displayText)")
            onStateChange?(state)
        }
    }

    /// Callback for state changes (called on arbitrary thread)
    var onStateChange: ((WhisperState) -> Void)?

    /// Selected language (nil = auto-detect). Persisted.
    var language: String? {
        get { UserDefaults.standard.string(forKey: Self.languageKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.languageKey) }
    }

    /// Currently active model
    private(set) var currentModel: WhisperModel

    private init() {
        // Load persisted model preference
        if let saved = UserDefaults.standard.string(forKey: Self.modelKey),
           let model = WhisperModel(rawValue: saved) {
            currentModel = model
        } else {
            currentModel = .small
        }
        initializeModel()
    }

    // MARK: - Model Management

    /// Switch to a different model. Triggers re-initialization.
    func selectModel(_ model: WhisperModel) {
        guard model != currentModel || !state.isReady else { return }
        currentModel = model
        UserDefaults.standard.set(model.rawValue, forKey: Self.modelKey)

        // Tear down existing model
        initLock.lock()
        whisperKit = nil
        state = .notLoaded
        initLock.unlock()

        initializeModel()
    }

    // MARK: - Initialization

    func initializeModel() {
        initLock.lock()
        guard !state.isReady else {
            initLock.unlock()
            return
        }
        if case .downloading = state { initLock.unlock(); return }
        if case .loading = state { initLock.unlock(); return }

        state = .downloading
        initLock.unlock()

        let modelName = currentModel.rawValue
        NSLog("WisperKbd: Initializing WhisperKit with model: \(modelName)")

        Task {
            do {
                self.state = .loading
                let kit = try await WhisperKit(
                    model: modelName,
                    verbose: false,
                    logLevel: .error
                )

                self.initLock.lock()
                self.whisperKit = kit
                self.state = .ready
                self.initLock.unlock()

            } catch {
                self.initLock.lock()
                self.state = .failed(error)
                self.initLock.unlock()
                NSLog("WisperKbd: ERROR — Failed to initialize WhisperKit: \(error)")
            }
        }
    }

    // MARK: - Transcription

    func transcribe(samples: [Float], completion: @escaping (String) -> Void) {
        guard state.isReady, let kit = whisperKit else {
            if case .failed = state {
                initializeModel()
            }
            return
        }

        guard !samples.isEmpty else { return }

        Task {
            do {
                let lang = self.language
                let options = DecodingOptions(
                    verbose: false,
                    task: .transcribe,
                    language: lang,
                    temperatureFallbackCount: 0,
                    sampleLength: 224,
                    usePrefillPrompt: false,
                    detectLanguage: lang == nil
                )

                let result = try await kit.transcribe(
                    audioArray: samples,
                    decodeOptions: options
                )

                let text = result
                    .compactMap { $0.text }
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if !text.isEmpty {
                    completion(text)
                }
            } catch {
                NSLog("WisperKbd: Transcription error: \(error)")
            }
        }
    }
}
