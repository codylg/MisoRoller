import SceneKit

/// A selectable post-process look for the dice scene. Each case supplies its
/// own `SCNTechnique`.
enum ShaderStyle: String, CaseIterable, Identifiable {
    case metal
    case pixel
    case glow

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pixel: "Pixel"
        case .metal: "Metal"
        case .glow: "Glow"
        }
    }

    /// Asset catalog name for this look's picker thumbnail.
    var thumbnailImageName: String {
        switch self {
        case .pixel: "ShaderPixel"
        case .metal: "ShaderMetal"
        case .glow: "ShaderGlow"
        }
    }

    /// The table this look renders against — each shader owns its own background.
    var background: BackgroundStyle {
        switch self {
        case .pixel: .paper
        case .metal: .chromatic
        case .glow: .chromaticSoft
        }
    }

    /// A fresh technique for this style. SCNTechnique carries per-view render
    /// targets, so each view gets its own instance rather than sharing a
    /// cached one.
    func makeTechnique() -> SCNTechnique? {
        switch self {
        case .pixel: PostProcessTechnique.make(fragmentShader: "dither_fragment")
        case .metal: PostProcessTechnique.makeBloomChain(prefix: "chromatic")
        case .glow: PostProcessTechnique.makeBloomChain(prefix: "glow")
        }
    }
}
