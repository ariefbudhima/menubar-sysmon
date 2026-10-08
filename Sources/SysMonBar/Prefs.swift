import Foundation

enum MenuBarStyle: String, CaseIterable {
    case ram
    case ramAndCPU
    case iconOnly

    var label: String {
        switch self {
        case .ram: return "RAM %"
        case .ramAndCPU: return "RAM + CPU"
        case .iconOnly: return "Icon only"
        }
    }

    var next: MenuBarStyle {
        let all = MenuBarStyle.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }
}

enum RefreshRate: Double, CaseIterable {
    case one = 1
    case two = 2
    case three = 3
    case five = 5
    case ten = 10

    var label: String { "\(Int(rawValue))s" }

    var next: RefreshRate {
        let all = RefreshRate.allCases
        let index = all.firstIndex(of: self) ?? 2
        return all[(index + 1) % all.count]
    }
}

final class Prefs {
    static let shared = Prefs()

    private enum Key {
        static let refreshInterval = "refreshIntervalSeconds"
        static let menuBarStyle = "menuBarStyle"
        static let showTopProcesses = "showTopProcesses"
        static let iconStyle = "iconStyle"
    }

    private let defaults = UserDefaults.standard

    var refreshInterval: RefreshRate {
        get {
            let value = defaults.double(forKey: Key.refreshInterval)
            return RefreshRate(rawValue: value) ?? .three
        }
        set { defaults.set(newValue.rawValue, forKey: Key.refreshInterval) }
    }

    var style: MenuBarStyle {
        get { MenuBarStyle(rawValue: defaults.string(forKey: Key.menuBarStyle) ?? "") ?? .ram }
        set { defaults.set(newValue.rawValue, forKey: Key.menuBarStyle) }
    }

    /// `.ring` by default: the original rounded-rect-plus-fill looked like a
    /// second battery sitting next to the real one.
    var iconStyle: IconStyleChoice {
        get { IconStyleChoice(rawValue: defaults.string(forKey: Key.iconStyle) ?? "") ?? .ring }
        set { defaults.set(newValue.rawValue, forKey: Key.iconStyle) }
    }

    var showTopProcesses: Bool {
        get {
            guard defaults.object(forKey: Key.showTopProcesses) != nil else { return true }
            return defaults.bool(forKey: Key.showTopProcesses)
        }
        set { defaults.set(newValue, forKey: Key.showTopProcesses) }
    }
}
