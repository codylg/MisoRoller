import Foundation

/// User-facing settings, persisted in UserDefaults. Shared app-wide rather than
/// threaded through the view hierarchy so the scene layer — which reads them off
/// the physics/render threads — can reach them directly.
final class Preferences: ObservableObject {
    static let shared = Preferences()

    @Published var soundEnabled: Bool {
        didSet { defaults.set(soundEnabled, forKey: Key.soundEnabled) }
    }

    @Published var shaderStyle: ShaderStyle {
        didSet { defaults.set(shaderStyle.rawValue, forKey: Key.shaderStyle) }
    }

    private enum Key {
        static let soundEnabled = "soundEnabled"
        static let shaderStyle = "shaderStyle"
    }

    private let defaults = UserDefaults.standard

    private init() {
        let defaults = UserDefaults.standard
        // `bool(forKey:)` reports false for an unset key, so "sound on by
        // default" has to be registered rather than inferred from a first read.
        defaults.register(defaults: [
            Key.soundEnabled: true,
            Key.shaderStyle: ShaderStyle.metal.rawValue
        ])
        soundEnabled = defaults.bool(forKey: Key.soundEnabled)
        shaderStyle = ShaderStyle(rawValue: defaults.string(forKey: Key.shaderStyle) ?? "") ?? .metal
    }
}
