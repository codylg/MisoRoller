import Foundation

/// How the table renders for a given shader look. The floor texture is baked
/// from this (see `DiceController.makeFloorImage`), so each shader owns its own
/// background rather than every look sharing one paper table.
struct BackgroundStyle: Hashable {
    /// Shape of the inner shadow.
    enum Vignette: Hashable {
        case none
        /// Feathered inward from a rounded rectangle that follows the device's
        /// screen corners. `band` is in world units. Good for a tight edge
        /// shadow — at larger bands the distance field's vertical medial axis
        /// shows up as a bright column down a tall screen.
        case roundedRect(band: Float, strength: Float)
        /// Elliptical falloff, in units of the half-extent: darkening ramps from
        /// `inner` to `outer` (1.0 being the screen edge, ~1.35 the corners).
        case radial(inner: Float, outer: Float, strength: Float)
    }

    /// Base luminance of the table before shadow and texture.
    var center: Float
    var vignette: Vignette
    /// Spacing of the baked dot grid, in dither cells. Nil for no dots.
    var dotSpacing: Int?
    /// Relative luminance swing of the low-frequency cloud field. Zero = flat.
    var cloudAmplitude: Float
    /// Cloud feature size — roughly how many blobs span the screen.
    var cloudScale: Float
    /// Soft wavy bands of shade drifting across the table. Zero = none.
    var bandAmplitude: Float = 0
    /// Roughly how many bands span the screen.
    var bandFrequency: Float = 3
    /// How far the bands wander off straight, in band-widths. At zero they're
    /// hard diagonal stripes; the noise offset is what makes them irregular.
    var bandWander: Float = 1

    /// The original paper table: tight inner shadow plus the sparse dot grid.
    static let paper = BackgroundStyle(
        center: 1.0, vignette: .roundedRect(band: 0.44, strength: 0.19),
        dotSpacing: 22, cloudAmplitude: 0, cloudScale: 1)

    /// A light table with a gentle radial falloff and soft cloud texture. The
    /// base sits in the pale pink/mint shoulder of the chromatic ramp so the
    /// background reads as tinted white rather than coloured, and the clouds only
    /// drift it between those two neighbouring bands. It stays below the die top
    /// faces (~1.0) so the dice remain the brightest thing on screen — which is
    /// also what feeds the bloom's bright pass.
    /// Metal's table. The wavy bands break up the flatness, and the vignette is
    /// kept light because Metal's shader keys its colour off how far a pixel's
    /// tone sits from the table's — a heavy vignette pushes the screen corners far
    /// enough to trip that and stains them.
    static let chromatic = BackgroundStyle(
        center: 0.80, vignette: .radial(inner: 0.25, outer: 1.25, strength: 0.08),
        dotSpacing: nil, cloudAmplitude: 0.16, cloudScale: 3.2,
        bandAmplitude: 0.13, bandFrequency: 2.4, bandWander: 1.5)

    /// Glow's table: the same thing before the bands, with a deeper vignette that
    /// its softer palette can carry.
    static let chromaticSoft = BackgroundStyle(
        center: 0.80, vignette: .radial(inner: 0.25, outer: 1.25, strength: 0.14),
        dotSpacing: nil, cloudAmplitude: 0.16, cloudScale: 3.2)
}

/// Small CPU value-noise field used to bake the cloud texture.
enum ValueNoise {
    static func fbm(_ x: Float, _ y: Float, octaves: Int = 4) -> Float {
        var sum: Float = 0, amplitude: Float = 0.5, frequency: Float = 1
        var total: Float = 0
        for _ in 0..<octaves {
            sum += amplitude * noise(x * frequency, y * frequency)
            total += amplitude
            frequency *= 2
            amplitude *= 0.5
        }
        return total > 0 ? sum / total : 0
    }

    private static func noise(_ x: Float, _ y: Float) -> Float {
        let xi = floorf(x), yi = floorf(y)
        let xf = x - xi, yf = y - yi
        let u = xf * xf * (3 - 2 * xf)
        let v = yf * yf * (3 - 2 * yf)
        let a = hash(xi, yi),     b = hash(xi + 1, yi)
        let c = hash(xi, yi + 1), d = hash(xi + 1, yi + 1)
        return (a * (1 - u) + b * u) * (1 - v) + (c * (1 - u) + d * u) * v
    }

    private static func hash(_ x: Float, _ y: Float) -> Float {
        var h = sinf(x * 127.1 + y * 311.7) * 43758.5453
        h -= floorf(h)
        return h
    }
}
