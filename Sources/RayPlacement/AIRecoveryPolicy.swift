import Combine
import Foundation

enum AIRecoveryProviderChangePolicy: String, Codable, CaseIterable, Sendable, Identifiable {
    case retrySelected
    case sameProviderModel
    case approvedProvider
    case askBeforeChange
    case neverChange

    var id: String { rawValue }

    var title: String {
        switch self {
        case .retrySelected: "Retry selected provider"
        case .sameProviderModel: "Allow another model in this provider"
        case .approvedProvider: "Allow explicitly approved providers"
        case .askBeforeChange: "Ask before changing provider"
        case .neverChange: "Never change provider automatically"
        }
    }
}

struct AIRecoveryPolicy: Codable, Equatable, Sendable {
    var automaticRetryEnabled: Bool = true
    var providerChange: AIRecoveryProviderChangePolicy = .retrySelected
    var approvedFallbackProviderIDs: Set<String> = []
    var maximumTransientAttempts: Int = 3
}

@MainActor
final class AIRecoveryPreferences: ObservableObject {
    static let shared = AIRecoveryPreferences()

    @Published var automaticRetryEnabled: Bool {
        didSet { defaults.set(automaticRetryEnabled, forKey: "lima.ai.recovery.auto-retry") }
    }
    @Published var providerChange: AIRecoveryProviderChangePolicy {
        didSet { defaults.set(providerChange.rawValue, forKey: "lima.ai.recovery.provider-change") }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = LimaTestEnvironment.userDefaults) {
        self.defaults = defaults
        automaticRetryEnabled = defaults.object(forKey: "lima.ai.recovery.auto-retry") as? Bool ?? true
        providerChange = AIRecoveryProviderChangePolicy(
            rawValue: defaults.string(forKey: "lima.ai.recovery.provider-change") ?? ""
        ) ?? .retrySelected
    }

    var snapshot: AIRecoveryPolicy {
        AIRecoveryPolicy(
            automaticRetryEnabled: automaticRetryEnabled,
            providerChange: providerChange,
            approvedFallbackProviderIDs: [],
            maximumTransientAttempts: 3
        )
    }
}
