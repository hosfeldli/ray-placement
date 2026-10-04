import Foundation

enum AIProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case openAI
    case anthropic
    case gemini
    case mistral
    case xAI
    case deepSeek
    case openRouter
    case openAICompatible
    case codexCLI
    case claudeCLI

    var isCLI: Bool { self == .codexCLI || self == .claudeCLI }
    static let writingProviders: [AIProvider] = allCases.filter { !$0.isCLI }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .gemini: return "Google Gemini"
        case .mistral: return "Mistral"
        case .xAI: return "xAI"
        case .deepSeek: return "DeepSeek"
        case .openRouter: return "OpenRouter"
        case .openAICompatible: return "Custom OpenAI-compatible"
        case .codexCLI: return "OpenAI Codex CLI"
        case .claudeCLI: return "Claude CLI"
        }
    }

    var defaultModel: String {
        modelOptions.first?.id ?? "local-model"
    }

    var modelOptions: [AIModelDescriptor] {
        switch self {
        case .openAI:
            return [
                .init(id: "gpt-5.6-luna", title: "GPT-5.6 Luna · Fast"),
                .init(id: "gpt-5.6-terra", title: "GPT-5.6 Terra · Quality"),
                .init(id: "gpt-4o-mini", title: "GPT-4o mini"),
                .init(id: "gpt-4.1-mini", title: "GPT-4.1 mini"),
                .init(id: "gpt-4.1", title: "GPT-4.1"),
                .init(id: "gpt-4o", title: "GPT-4o")
            ]
        case .anthropic:
            return [
                .init(id: "claude-3-5-haiku-latest", title: "Claude 3.5 Haiku"),
                .init(id: "claude-3-7-sonnet-latest", title: "Claude 3.7 Sonnet"),
                .init(id: "claude-sonnet-4-20250514", title: "Claude Sonnet 4")
            ]
        case .gemini:
            return [
                .init(id: "gemini-2.0-flash", title: "Gemini 2.0 Flash"),
                .init(id: "gemini-2.5-flash", title: "Gemini 2.5 Flash"),
                .init(id: "gemini-2.5-pro", title: "Gemini 2.5 Pro")
            ]
        case .mistral:
            return [
                .init(id: "mistral-small-latest", title: "Mistral Small"),
                .init(id: "mistral-large-latest", title: "Mistral Large"),
                .init(id: "codestral-latest", title: "Codestral")
            ]
        case .xAI:
            return [
                .init(id: "grok-3-mini", title: "Grok 3 mini"),
                .init(id: "grok-3", title: "Grok 3")
            ]
        case .deepSeek:
            return [
                .init(id: "deepseek-chat", title: "DeepSeek Chat"),
                .init(id: "deepseek-reasoner", title: "DeepSeek Reasoner")
            ]
        case .openRouter:
            return [
                .init(id: "openai/gpt-4o-mini", title: "OpenAI · GPT-4o mini"),
                .init(id: "anthropic/claude-3.5-haiku", title: "Anthropic · Claude 3.5 Haiku"),
                .init(id: "google/gemini-2.0-flash-001", title: "Google · Gemini 2.0 Flash")
            ]
        case .openAICompatible, .codexCLI, .claudeCLI:
            return []
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openAI: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta"
        case .mistral: return "https://api.mistral.ai/v1"
        case .xAI: return "https://api.x.ai/v1"
        case .deepSeek: return "https://api.deepseek.com/v1"
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .openAICompatible: return "http://127.0.0.1:1234/v1"
        case .codexCLI, .claudeCLI: return ""
        }
    }

    var usesChatCompletions: Bool {
        self != .anthropic && self != .gemini && !isCLI
    }
}

struct AIModelDescriptor: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
}

struct AIProviderConfiguration: Sendable {
    let provider: AIProvider
    let apiKey: String
    let model: String
    let baseURL: String
}

/// Compatibility aliases keep grammar feature call sites source-compatible
/// while the shared AI provider layer is adopted feature by feature.
typealias DeveloperGrammarProvider = AIProvider
typealias DeveloperGrammarModelOption = AIModelDescriptor
typealias DeveloperGrammarConfiguration = AIProviderConfiguration

/// Preferences persist model identity, never provider credentials.
struct AIModelReference: Codable, Hashable, Sendable {
    var provider: AIProvider
    var modelID: String

    init(provider: AIProvider, modelID: String) {
        self.provider = provider
        self.modelID = modelID
    }
}

extension AIProvider {
    static let chatProviders: [AIProvider] = [.openAI, .anthropic, .gemini, .openAICompatible, .codexCLI, .claudeCLI]

    var chatModels: [AIModelOption] {
        switch self {
        case .openAI:
            return AIModelOption.fallbackModels
        case .anthropic:
            return modelOptions.map { AIModelOption(id: $0.id, displayName: $0.title, supportsReasoning: false) }
        case .gemini:
            return modelOptions.map { AIModelOption(id: $0.id, displayName: $0.title, supportsReasoning: false) }
        case .openAICompatible:
            return [AIModelOption(id: "local-model", displayName: "Custom model", supportsReasoning: false)]
        case .codexCLI, .claudeCLI:
            return [AIModelOption(id: "default", displayName: "CLI default", supportsReasoning: false)]
        case .mistral, .xAI, .deepSeek, .openRouter:
            return modelOptions.map { AIModelOption(id: $0.id, displayName: $0.title, supportsReasoning: false) }
        }
    }

    var defaultChatModel: String {
        switch self {
        case .openAI: return "gpt-5.4"
        case .anthropic: return "claude-sonnet-4-20250514"
        case .gemini: return "gemini-2.5-flash"
        case .openAICompatible: return "local-model"
        case .codexCLI, .claudeCLI: return "default"
        case .mistral, .xAI, .deepSeek, .openRouter: return defaultModel
        }
    }
}
