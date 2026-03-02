import Foundation
import Combine

/// Persists user-configurable settings to UserDefaults.
/// Injected as an @EnvironmentObject from AppCoordinator.
final class AppSettings: ObservableObject {

    // MARK: - Security
    @Published var isBiometricLockEnabled: Bool {
        didSet { UserDefaults.standard.set(isBiometricLockEnabled, forKey: Keys.biometricLock) }
    }
    @Published var autoLockTimeout: AutoLockTimeout {
        didSet { UserDefaults.standard.set(autoLockTimeout.rawValue, forKey: Keys.autoLockTimeout) }
    }

    // MARK: - AutoLockTimeout

    enum AutoLockTimeout: Int, CaseIterable, Identifiable {
        case oneMinute   = 60
        case fiveMinutes = 300
        case fifteenMinutes = 900
        case never       = 0

        var id: Int { rawValue }

        var label: String {
            switch self {
            case .oneMinute:      return "1 minute"
            case .fiveMinutes:    return "5 minutes"
            case .fifteenMinutes: return "15 minutes"
            case .never:          return "Never"
            }
        }
    }

    // MARK: - Init

    init() {
        self.isBiometricLockEnabled = UserDefaults.standard.bool(forKey: Keys.biometricLock)
        let rawTimeout = UserDefaults.standard.integer(forKey: Keys.autoLockTimeout)
        self.autoLockTimeout = AutoLockTimeout(rawValue: rawTimeout) ?? .fiveMinutes
    }

    // MARK: - Keys
    private enum Keys {
        static let biometricLock  = "sv.biometricLockEnabled"
        static let autoLockTimeout = "sv.autoLockTimeout"
    }
}
