import SceneKit

/// Builds the render-to-texture + fullscreen-quad technique every shader look
/// shares. Only the fragment function differs between styles.
enum PostProcessTechnique {
    static func make(fragmentShader: String) -> SCNTechnique? {
        let dict: [String: Any] = [
            "passes": [
                "scene_pass": [
                    "draw": "DRAW_SCENE",
                    "outputs": ["color": "scene_color"]
                ],
                "post_pass": [
                    "draw": "DRAW_QUAD",
                    "metalVertexShader": "post_vertex",
                    "metalFragmentShader": fragmentShader,
                    "inputs": ["colorSampler": "scene_color"],
                    "outputs": ["color": "COLOR"]
                ]
            ],
            "sequence": ["scene_pass", "post_pass"],
            "targets": ["scene_color": ["type": "color"]]
        ]
        return SCNTechnique(dictionary: dict)
    }

    /// A bloom chain: a noise bake, bright-pass + downsample, separable blur, then
    /// a composite that grades the scene and blends the glow over it. The bloom
    /// targets run at 1/8 scale — cheap, and the blur radius in *screen* pixels
    /// grows with the downscale, which is what makes the glow wide.
    ///
    /// The noise pass is a pure optimisation: both composites' warp fields depend
    /// only on screen position, so they're evaluated once per quarter-scale texel
    /// here instead of per pixel per frame (see `post_noise_fragment`). It's
    /// shared rather than prefixed — both looks want the same fields.
    ///
    /// `prefix` selects the look's four fragment functions
    /// (`<prefix>_bright_fragment` and so on), so Metal and Glow share this
    /// structure while keeping their own palettes.
    static func makeBloomChain(prefix: String) -> SCNTechnique? {
        func quad(_ fragment: String, inputs: [String: String], output: String) -> [String: Any] {
            [
                "draw": "DRAW_QUAD",
                "metalVertexShader": "post_vertex",
                "metalFragmentShader": fragment,
                "inputs": inputs,
                "outputs": ["color": output]
            ]
        }
        let dict: [String: Any] = [
            "passes": [
                "scene_pass": [
                    "draw": "DRAW_SCENE",
                    "outputs": ["color": "scene_color"]
                ],
                "noise_pass": quad("post_noise_fragment",
                                   inputs: ["colorSampler": "scene_color"],
                                   output: "noise"),
                "bright_pass": quad("\(prefix)_bright_fragment",
                                    inputs: ["colorSampler": "scene_color"],
                                    output: "bloom_a"),
                "blur_h_pass": quad("\(prefix)_blur_h_fragment",
                                    inputs: ["colorSampler": "bloom_a"],
                                    output: "bloom_b"),
                "blur_v_pass": quad("\(prefix)_blur_v_fragment",
                                    inputs: ["colorSampler": "bloom_b"],
                                    output: "bloom_c"),
                "composite_pass": quad("\(prefix)_composite_fragment",
                                       inputs: ["colorSampler": "scene_color",
                                                "bloomSampler": "bloom_c",
                                                "noiseSampler": "noise"],
                                       output: "COLOR")
            ],
            "sequence": ["scene_pass", "noise_pass", "bright_pass",
                         "blur_h_pass", "blur_v_pass", "composite_pass"],
            "targets": [
                "scene_color": ["type": "color"],
                "noise": ["type": "color", "scaleFactor": 0.25],
                "bloom_a": ["type": "color", "scaleFactor": 0.125],
                "bloom_b": ["type": "color", "scaleFactor": 0.125],
                "bloom_c": ["type": "color", "scaleFactor": 0.125]
            ]
        ]
        return SCNTechnique(dictionary: dict)
    }
}
