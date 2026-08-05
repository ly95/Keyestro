import Foundation

@MainActor
protocol SettingsPersisting: AnyObject {
    func object(forKey key: String) -> Any?
    func integer(forKey key: String) -> Int
    func string(forKey key: String) -> String?
    func bool(forKey key: String) -> Bool
    func set(_ value: Bool, forKey key: String) throws
    func set(_ value: String, forKey key: String) throws
}

@MainActor
final class UserDefaultsSettingsPersistence: SettingsPersisting {
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func object(forKey key: String) -> Any? { defaults.object(forKey: key) }
    func integer(forKey key: String) -> Int { defaults.integer(forKey: key) }
    func string(forKey key: String) -> String? { defaults.string(forKey: key) }
    func bool(forKey key: String) -> Bool { defaults.bool(forKey: key) }
    func set(_ value: Bool, forKey key: String) throws { defaults.set(value, forKey: key) }
    func set(_ value: String, forKey key: String) throws { defaults.set(value, forKey: key) }
}
