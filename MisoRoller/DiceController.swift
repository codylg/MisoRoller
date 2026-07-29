import SceneKit
import UIKit
import simd
import QuartzCore
import Combine

struct RollResult: Identifiable {
    let id = UUID()
    let type: DieType
    let value: Int
}

final class DiceController: NSObject, ObservableObject, SCNSceneRendererDelegate, SCNPhysicsContactDelegate {
    enum Phase: Equatable { case picking, rolling, settled }

    private static let diceCategory: Int = 1 << 0
    private static let boundaryCategory: Int = 1 << 1

    @Published var phase: Phase = .picking
    @Published var counts: [DieType: Int]
    @Published private(set) var results: [RollResult] = []

    static let maxDice = 16
    let scene = SCNScene()

    var totalCount: Int { counts.values.reduce(0, +) }

    private var dice: [(node: SCNNode, model: DieModel)] = []
    private let diceRoot = SCNNode()
    private var wallsNode: SCNNode?
    private var floorVisualNode: SCNNode?
    private var halfWidth: Float = 5
    private let halfHeight: Float = 8   // camera orthographicScale (world units, screen vertical)
    private var backgroundStyle: BackgroundStyle = .paper
    private var viewPointSize: CGSize = .zero
    private let gate = ContactGate()
    private var soundSubscription: AnyCancellable?
    private var stableFrames = 0
    private var rollStart: TimeInterval = -1
    private let rollTimeout: TimeInterval = 5   // hard cap in case a die never settles

    // Impact-sound state. Contacts fire on the physics thread; we gate on the
    // approach speed along the contact normal (collisionImpulse is 0 in didBegin)
    // so settling jitter stays silent, plus per-die and global cooldowns so a
    // pile doesn't machine-gun. Dice-vs-dice contacts get a high "tick"; dice-vs
    // -surface/edge contacts get the deep "tock".
    private var lastImpactTime: [ObjectIdentifier: CFTimeInterval] = [:]
    private var lastAnyImpact: CFTimeInterval = 0
    private let perDieCooldown: CFTimeInterval = 0.05
    private let globalMinSpacing: CFTimeInterval = 0.02
    /// Recorded samples (real dice). Table hits come in two flavours — the loud
    /// initial landing and the softer subsequent bounces/rolls — chosen by impact
    /// energy, since a hard hit differs in timbre, not just level.
    private let sounds = SoundBank()
    private let hardHitSpeed: Float = 4.0   // approach speed above which a table hit is "hard"

    /// The two flags the impact-sound callback tests, behind a lock because every
    /// one of them is written on a different thread from the one that reads it:
    /// `simulating` is set on main (`roll`) and cleared on the render thread
    /// (settle detection), while the callback itself runs on the physics thread,
    /// and `soundEnabled` mirrors a `@Published` property written on main.
    ///
    /// Reading `Preferences.shared.soundEnabled` directly from the physics thread
    /// — which is what this replaces — is a data race on an `ObservableObject`,
    /// benign-looking but undefined, and exactly what Swift 6's strict
    /// concurrency checking rejects. Mirroring the value costs one uncontended
    /// acquisition inside a callback that's already doing dictionary work.
    private final class ContactGate {
        private let lock = NSLock()
        private var simulating = false
        private var soundEnabled = true

        /// True only when a roll is live *and* sound is on — the single test the
        /// contact callback needs.
        var isOpen: Bool { lock.withLock { simulating && soundEnabled } }
        var isSimulating: Bool { lock.withLock { simulating } }
        var soundIsEnabled: Bool { lock.withLock { soundEnabled } }

        func setSimulating(_ value: Bool) { lock.withLock { simulating = value } }
        func setSoundEnabled(_ value: Bool) { lock.withLock { soundEnabled = value } }
    }

    /// The three recorded sample sets.
    ///
    /// Loading and decoding 24 WAVs takes long enough to be worth keeping off the
    /// launch path, so the bank starts empty and fills on a background queue.
    /// That fill can therefore land while the physics thread is already reading —
    /// hence the lock. Reads are one uncontended acquisition inside a contact
    /// callback that's already doing dictionary work, so it costs nothing.
    private final class SoundBank {
        private let lock = NSLock()
        private var tick: [SCNAudioSource] = []
        private var tockHard: [SCNAudioSource] = []
        private var tockSoft: [SCNAudioSource] = []

        func fill(tick: [SCNAudioSource], tockHard: [SCNAudioSource], tockSoft: [SCNAudioSource]) {
            lock.withLock {
                self.tick = tick
                self.tockHard = tockHard
                self.tockSoft = tockSoft
            }
        }

        /// Empty until the background load finishes, so callers naturally play
        /// nothing for the brief window before the samples are ready.
        func sources(diceDice: Bool, hard: Bool) -> [SCNAudioSource] {
            lock.withLock { diceDice ? tick : (hard ? tockHard : tockSoft) }
        }

        var all: [SCNAudioSource] { lock.withLock { tick + tockHard + tockSoft } }
    }

    private static func loadSources(prefix: String) -> [SCNAudioSource] {
        (1...8).compactMap { i in
            guard let source = SCNAudioSource(fileNamed: "\(prefix)\(i).wav") else { return nil }
            source.isPositional = false
            source.load()
            return source
        }
    }

    override init() {
        counts = Dictionary(uniqueKeysWithValues: DieType.allCases.map { ($0, 0) })
        super.init()
        setupScene()
        loadSoundsInBackground()
        // Mirrors the preference into the gate (fires immediately with the
        // current value) and re-masks any live dice, so turning sound off stops
        // contacts being reported at all rather than reporting them for a
        // callback that will only discard them.
        soundSubscription = Preferences.shared.$soundEnabled.sink { [weak self] enabled in
            self?.applySoundSetting(enabled)
        }
    }

    private func applySoundSetting(_ enabled: Bool) {
        gate.setSoundEnabled(enabled)
        let mask = Self.contactMask(soundEnabled: enabled)
        for die in dice { die.node.physicsBody?.contactTestBitMask = mask }
    }

    /// Contact *reporting* only — collision response is `collisionBitMask` and is
    /// untouched, so the dice still bounce off each other and the walls normally
    /// with sound off. There is simply nothing listening.
    private static func contactMask(soundEnabled: Bool) -> Int {
        soundEnabled ? (diceCategory | boundaryCategory) : 0
    }

    /// Decoding the samples blocks whoever runs it, and on the launch path that's
    /// the first frame. Nothing needs them until the first collision, which is
    /// several seconds of dice-picking away, so the whole thing moves off-thread
    /// and the audio warm-up chains onto the end of it.
    private func loadSoundsInBackground() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let tick = Self.loadSources(prefix: "tick")
            let tockHard = Self.loadSources(prefix: "tockhard")
            let tockSoft = Self.loadSources(prefix: "tocksoft")
            guard let self else { return }
            self.sounds.fill(tick: tick, tockHard: tockHard, tockSoft: tockSoft)
            // Back to main to touch the scene graph.
            DispatchQueue.main.async { self.warmUpAudio() }
        }
    }

    /// Primes SceneKit's audio playback graph at launch so the first real
    /// collision doesn't stall while it lazily spins up (node/engine setup,
    /// hardware I/O activation). Plays every distinct sample once at an
    /// effectively silent volume; `source.volume` is overwritten before every
    /// real hit anyway (see `physicsWorld(_:didBegin:)`), so this has no audible
    /// effect and doesn't interfere with later playback.
    private func warmUpAudio() {
        let warmupNode = SCNNode()
        scene.rootNode.addChildNode(warmupNode)
        for source in sounds.all {
            source.volume = 0.0001
            warmupNode.runAction(SCNAction.playAudio(source, waitForCompletion: false))
        }
    }

    // MARK: - Render pacing

    /// The view driving this scene, so rendering can be paced from here.
    ///
    /// Outside a roll the scene is completely static — `freezeDice` takes every
    /// die out of the simulation, and in the picking phase there are no dice at
    /// all — and nothing in the post-process shaders varies with time either. A
    /// continuously-rendering view therefore spends the entire idle session
    /// re-drawing an identical frame through the full chain (scene, bright pass,
    /// two blurs, composite) at up to 120Hz. Rendering runs while the physics is
    /// live, plus a short grace period after any one-off change, and is otherwise
    /// off.
    private weak var renderView: SCNView?
    private var idleWorkItem: DispatchWorkItem?
    /// Long enough for a change to be laid out, rendered and presented, short
    /// enough that nothing keeps spinning after it.
    private let renderGracePeriod: TimeInterval = 0.2

    func attach(to view: SCNView) {
        renderView = view
        requestRedraw()
    }

    private func setRendering(_ on: Bool) {
        guard let view = renderView else { return }
        view.isPlaying = on
        view.rendersContinuously = on
    }

    /// Renders continuously until `endContinuousRendering` — used for the roll,
    /// where the scene changes every frame.
    private func beginContinuousRendering() {
        idleWorkItem?.cancel()
        idleWorkItem = nil
        setRendering(true)
    }

    /// Renders for a moment, then idles. Everything that changes the scene *once*
    /// — the technique swap, the floor rebuild, freezing the dice — goes through
    /// here, so the change reaches the screen without leaving the view running.
    /// Main thread only.
    func requestRedraw() {
        idleWorkItem?.cancel()
        setRendering(true)
        let item = DispatchWorkItem { [weak self] in
            self?.setRendering(false)
            self?.idleWorkItem = nil
        }
        idleWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + renderGracePeriod, execute: item)
    }

    // MARK: - Scene setup

    private func setupScene() {
        scene.physicsWorld.gravity = SCNVector3(0, -30, 0)
        scene.physicsWorld.contactDelegate = self

        // The visible table is a finite plane (built in rebuildWalls once the view
        // size is known) with the inner-shadow vignette baked into its texture, so
        // the shadow lives on the background layer beneath the dice and is dithered
        // along with everything else.

        let floorBody = SCNNode()
        floorBody.position = SCNVector3(0, -0.5, 0)
        floorBody.physicsBody = SCNPhysicsBody(
            type: .static,
            shape: SCNPhysicsShape(geometry: SCNBox(width: 200, height: 1, length: 200, chamferRadius: 0)))
        floorBody.physicsBody?.friction = 0.6
        floorBody.physicsBody?.restitution = 0.4
        floorBody.physicsBody?.categoryBitMask = Self.boundaryCategory
        scene.rootNode.addChildNode(floorBody)

        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.orthographicScale = Double(halfHeight)
        camera.zNear = 0.1
        camera.zFar = 100
        let camNode = SCNNode()
        camNode.camera = camera
        camNode.position = SCNVector3(0, 40, 0)
        camNode.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        scene.rootNode.addChildNode(camNode)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 380
        scene.rootNode.addChildNode(ambient)

        let sun = SCNNode()
        sun.light = SCNLight()
        sun.light?.type = .directional
        sun.light?.intensity = 800
        sun.light?.castsShadow = true
        sun.light?.shadowRadius = 6
        sun.light?.shadowColor = UIColor(white: 0, alpha: 0.95)
        // Light travels toward screen-(right, down); its source is conceptually
        // the opposite direction, i.e. screen top-left. Same steep overhead angle
        // as before (dominant -Y), just mirrored top/bottom from the previous
        // bottom-left source. Set via an explicit direction rather than hand-tuned
        // Euler angles, since top-left/bottom-left isn't a simple single-axis flip
        // under this camera's rotation.
        let lightDirection = simd_normalize(simd_float3(0.233, -0.932, 0.277))
        sun.simdOrientation = simd_quatf(from: simd_float3(0, 0, -1), to: lightDirection)
        scene.rootNode.addChildNode(sun)

        scene.rootNode.addChildNode(diceRoot)
    }

    // MARK: - Bounds / walls

    /// Swaps the table appearance when the shader look changes. No-op until the
    /// view has reported its size, since the floor is built on first layout.
    func applyBackground(_ style: BackgroundStyle) {
        guard style != backgroundStyle else { return }
        backgroundStyle = style
        if wallsNode != nil { rebuildFloorVisual() }
        requestRedraw()
    }

    func viewSizeChanged(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        viewPointSize = size
        let newHalfWidth = halfHeight * Float(size.width / size.height)
        if wallsNode == nil || abs(newHalfWidth - halfWidth) > 0.05 {
            halfWidth = newHalfWidth
            rebuildWalls()
        }
        requestRedraw()
    }

    private func rebuildWalls() {
        wallsNode?.removeFromParentNode()
        let container = SCNNode()
        let t: Float = 2, h: Float = 16
        let w = halfWidth, d = halfHeight
        let specs: [(size: simd_float3, position: simd_float3)] = [
            ([t, h, d * 2 + t * 2], [w + t / 2, h / 2, 0]),
            ([t, h, d * 2 + t * 2], [-w - t / 2, h / 2, 0]),
            ([w * 2 + t * 2, h, t], [0, h / 2, d + t / 2]),
            ([w * 2 + t * 2, h, t], [0, h / 2, -d - t / 2]),
            ([w * 2 + t * 2, t, d * 2 + t * 2], [0, h + t / 2, 0])   // lid
        ]
        for spec in specs {
            let node = SCNNode()
            node.simdPosition = spec.position
            let box = SCNBox(width: CGFloat(spec.size.x), height: CGFloat(spec.size.y),
                             length: CGFloat(spec.size.z), chamferRadius: 0)
            node.physicsBody = SCNPhysicsBody(type: .static, shape: SCNPhysicsShape(geometry: box))
            node.physicsBody?.restitution = 0.6
            node.physicsBody?.friction = 0.1
            node.physicsBody?.categoryBitMask = Self.boundaryCategory
            container.addChildNode(node)
        }
        scene.rootNode.addChildNode(container)
        wallsNode = container
        rebuildFloorVisual()
    }

    /// Cached table textures, one per style. Baking one is expensive enough to
    /// stall visibly (see the note in `makeFloorImage`), and switching shader
    /// looks in the picker used to redo that work from scratch on every tap —
    /// including for a style whose table had already been baked moments earlier.
    /// Keyed by style alone; the whole cache is dropped if the view size changes,
    /// since the texture resolution and world extents both derive from it.
    private var floorImageCache: [BackgroundStyle: UIImage] = [:]
    private var floorCacheSize: CGSize = .zero

    private func floorImage() -> UIImage {
        if floorCacheSize != viewPointSize {
            floorImageCache.removeAll()
            floorCacheSize = viewPointSize
        }
        if let cached = floorImageCache[backgroundStyle] { return cached }
        let image = makeFloorImage(halfW: halfWidth, halfH: halfHeight)
        floorImageCache[backgroundStyle] = image
        return image
    }

    private func rebuildFloorVisual() {
        floorVisualNode?.removeFromParentNode()
        let plane = SCNPlane(width: CGFloat(halfWidth * 2), height: CGFloat(halfHeight * 2))
        let mat = SCNMaterial()
        mat.diffuse.contents = floorImage()
        mat.diffuse.wrapS = .clamp
        mat.diffuse.wrapT = .clamp
        // Nearest sampling (no mipmaps) so the single-texel dots stay crisp instead
        // of getting blurred into blobs when the camera renders the plane.
        mat.diffuse.magnificationFilter = .nearest
        mat.diffuse.minificationFilter = .nearest
        mat.diffuse.mipFilter = .none
        mat.lightingModel = .lambert
        plane.materials = [mat]
        let node = SCNNode(geometry: plane)
        node.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)   // lay flat (XZ plane, facing up)
        node.position = SCNVector3(0, -0.02, 0)              // just below the dice rest height
        node.castsShadow = false
        scene.rootNode.addChildNode(node)
        floorVisualNode = node
    }

    /// Table texture: the inner-shadow vignette, the optional cloud field and the
    /// optional dot grid are all baked in, so they live on the background layer
    /// beneath the dice and get processed by whatever shader is running.
    /// Distances are in world units so they read consistently regardless of aspect.
    private func makeFloorImage(halfW: Float, halfH: Float) -> UIImage {
        // Texture resolution = the shader's dither-cell grid (screen points), so one
        // texel maps to exactly one 3px dither cell → single-pixel dots that line up
        // with the shader. (Matches DiceSceneView's pixelSize of 3.)
        let resW = max(64, Int(viewPointSize.width.rounded()))
        let resH = max(64, Int(viewPointSize.height.rounded()))
        let style = backgroundStyle
        let center = style.center
        let fw = halfW * 2, fh = halfH * 2
        // Match the actual device screen corner radius so the shadow follows the
        // real rounded corner on every device (falls back to ~55pt).
        let cornerPts = (UIScreen.main.value(forKey: "_displayCornerRadius") as? CGFloat) ?? 55
        let worldPerPoint = viewPointSize.height > 0 ? fh / Float(viewPointSize.height) : fh / 874
        let rc = min(min(halfW, halfH), Float(cornerPts) * worldPerPoint)
        // RGBA — SceneKit/Metal rejects single-channel grayscale textures.
        var bytes = [UInt8](repeating: 255, count: resW * resH * 4)
        // The noise-heavy math below is the most expensive thing on the launch
        // path (measured ~0.3-0.4s single-threaded at full screen resolution) —
        // long enough that the picker panel and the rest of the UI were already
        // on screen while the background stayed black, which is what read as
        // the shader "not applying" for a moment. Each row only ever writes its
        // own slice of `bytes`, so splitting rows across cores is safe — same
        // bytes, same math, just computed concurrently instead of one at a time.
        bytes.withUnsafeMutableBufferPointer { bytes in
            DispatchQueue.concurrentPerform(iterations: resH) { j in
                for i in 0..<resW {
                    let u = (Float(i) + 0.5) / Float(resW)
                    let v = (Float(j) + 0.5) / Float(resH)
                    let px = (u - 0.5) * fw, py = (v - 0.5) * fh
                    var lumF = center
                    switch style.vignette {
                    case .none:
                        break
                    case let .roundedRect(band, strength):
                        // Distance inside a rounded rectangle (0 at the rounded boundary).
                        let qx = abs(px) - (halfW - rc), qy = abs(py) - (halfH - rc)
                        let sd = hypotf(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - rc
                        let distInside = -sd
                        let t = distInside < 0 ? 0 : max(0, min(1, 1 - distInside / band))
                        let dark = t * t * (3 - 2 * t)     // smoothstep falloff
                        lumF *= (1 - dark * strength)
                    case let .radial(inner, outer, strength):
                        let r = hypotf(px / halfW, py / halfH)
                        let t = max(0, min(1, (r - inner) / max(outer - inner, 1e-5)))
                        let dark = t * t * (3 - 2 * t)
                        lumF *= (1 - dark * strength)
                    }

                    // Soft cloud field — low-frequency value noise, so the background
                    // drifts across several bands of the shader's palette instead of
                    // reading as one flat tone. Applied as a relative swing so it
                    // fades out with the vignette rather than speckling the dark edge.
                    if style.cloudAmplitude > 0 {
                        let s = style.cloudScale
                        let cloud = ValueNoise.fbm(u * s * Float(resW) / Float(resH), v * s)
                        lumF *= 1 + (cloud - 0.5) * style.cloudAmplitude
                    }

                    // Soft wavy bands of shade. A diagonal sine whose phase is pushed
                    // around by a noise field, so the bands bend and vary in width
                    // instead of reading as stripes. Baked in like everything else
                    // here, so the shader grades them as real scene luminance rather
                    // than having to fake depth in the background.
                    if style.bandAmplitude > 0 {
                        let wander = ValueNoise.fbm(u * 1.7, v * 1.7, octaves: 3) - 0.5
                        let phase = (u * 0.55 + v) * style.bandFrequency + wander * style.bandWander
                        let band = (sinf(phase * 2 * .pi) + 1) / 2      // 0...1
                        lumF *= 1 - band * style.bandAmplitude
                    }

                    // Single-texel offset grid dots (alternate dot-rows shifted a half step).
                    if let dotSpacing = style.dotSpacing, j % dotSpacing == 0 {
                        let off = ((j / dotSpacing) % 2 == 0) ? 0 : dotSpacing / 2
                        if (i + off) % dotSpacing == 0 { lumF = 0 }   // stamp 1px dot (→ ink)
                    }

                    let lum = UInt8(max(0, min(1, lumF)) * 255)
                    let p = (j * resW + i) * 4
                    bytes[p] = lum; bytes[p + 1] = lum; bytes[p + 2] = lum; bytes[p + 3] = 255
                }
            }
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: &bytes, width: resW, height: resH, bitsPerComponent: 8,
                            bytesPerRow: resW * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return UIImage(cgImage: ctx.makeImage()!)
    }

    // MARK: - Rolling

    func roll() {
        guard totalCount > 0 else { return }
        clearDice()
        results = []
        phase = .rolling
        var toRoll: [DieType] = []
        for type in DieType.allCases {
            toRoll.append(contentsOf: Array(repeating: type, count: counts[type] ?? 0))
        }
        spawn(Array(toRoll.prefix(Self.maxDice)))
        stableFrames = 0
        rollStart = -1
        gate.setSimulating(true)
        beginContinuousRendering()
    }

    private func spawn(_ types: [DieType]) {
        let n = types.count
        for (i, type) in types.enumerated() {
            let model = DiceGeometry.model(for: type)
            let node = SCNNode(geometry: model.geometry)
            let angle = Float(i) / Float(max(n, 1)) * 2 * .pi + Float.random(in: -0.25...0.25)
            node.position = SCNVector3(cos(angle) * halfWidth * 0.6,
                                       3.5 + Float(i % 4) * 1.3,
                                       sin(angle) * halfHeight * 0.6)
            node.simdOrientation = simd_quatf(angle: Float.random(in: 0...(2 * .pi)),
                                              axis: randomAxis())

            // Shared, cached collision shape — see DiceGeometry.physicsShape.
            let body = SCNPhysicsBody(type: .dynamic, shape: DiceGeometry.physicsShape(for: type))
            // Heavier than SceneKit's auto-computed mass (still scaled by each
            // die's own volume, so relative size differences are preserved) —
            // collision impulses move a heavier body less, which is what reads
            // as "floaty" vs. grounded during the tumble/bounce, not free-fall
            // speed (gravity's acceleration is mass-independent).
            body.mass *= 1.8
            body.restitution = 0.45
            body.friction = 0.55
            body.rollingFriction = 0.06
            body.damping = 0.05
            body.angularDamping = 0.1
            body.categoryBitMask = Self.diceCategory
            body.contactTestBitMask = Self.contactMask(soundEnabled: gate.soundIsEnabled)
            node.physicsBody = body
            diceRoot.addChildNode(node)
            dice.append((node, model))

            let target = simd_float3(Float.random(in: -1.5...1.5), 0, Float.random(in: -1.5...1.5))
            var dir = target - simd_float3(node.position.x, 0, node.position.z)
            dir.y = 0
            dir = simd_normalize(dir)
            let speed = Float.random(in: 8...13)
            body.velocity = SCNVector3(dir.x * speed, Float.random(in: -3 ... -1), dir.z * speed)
            let spin = randomAxis()
            body.angularVelocity = SCNVector4(spin.x, spin.y, spin.z, Float.random(in: 12...28))
        }
    }

    private func randomAxis() -> simd_float3 {
        simd_normalize(simd_float3.random(in: -1...1) + [0.01, 0.01, 0.01])
    }

    private func clearDice() {
        dice.forEach { $0.node.removeFromParentNode() }
        dice = []
        lastImpactTime.removeAll()
    }

    // MARK: - Impact sounds (physics thread)

    func physicsWorld(_ world: SCNPhysicsWorld, didBegin contact: SCNPhysicsContact) {
        guard gate.isOpen,
              let bodyA = contact.nodeA.physicsBody,
              let bodyB = contact.nodeB.physicsBody else { return }
        let aDie = bodyA.categoryBitMask & Self.diceCategory != 0
        let bDie = bodyB.categoryBitMask & Self.diceCategory != 0
        guard aDie || bDie else { return }
        let diceDice = aDie && bDie

        // collisionImpulse is 0 in didBegin, so gauge the hit from the closing
        // speed along the contact normal.
        let vA = simd_float3(Float(bodyA.velocity.x), Float(bodyA.velocity.y), Float(bodyA.velocity.z))
        let vB = simd_float3(Float(bodyB.velocity.x), Float(bodyB.velocity.y), Float(bodyB.velocity.z))
        let nrm = simd_float3(Float(contact.contactNormal.x), Float(contact.contactNormal.y), Float(contact.contactNormal.z))
        let approach = abs(simd_dot(vA - vB, nrm))
        let minSpeed: Float = diceDice ? 1.3 : 1.8
        guard approach > minSpeed else { return }

        let now = CACurrentMediaTime()
        guard now - lastAnyImpact > globalMinSpacing else { return }
        let node = aDie ? contact.nodeA : contact.nodeB
        let id = ObjectIdentifier(node)
        guard now - (lastImpactTime[id] ?? 0) > perDieCooldown else { return }
        lastImpactTime[id] = now
        lastAnyImpact = now

        let isHardTableHit = !diceDice && approach > hardHitSpeed
        let sources = sounds.sources(diceDice: diceDice, hard: isHardTableHit)
        guard let source = sources.randomElement() else { return }
        let loud = min(1, max(0, (approach - minSpeed) / 10))
        var volume = (diceDice ? 0.30 : 0.45) + loud * 0.5
        // Subsequent (softer) table hits, quieter still — the loud initial
        // landing stays as-is.
        if !diceDice && !isHardTableHit { volume *= 0.75 }
        source.volume = volume
        // Subtle only: these are real recordings, so a wide pitch shift would undo
        // the realism. 8 variants per set already provide most of the variation.
        source.rate = Float.random(in: 0.94...1.06)
        node.runAction(SCNAction.playAudio(source, waitForCompletion: false))
    }

    // MARK: - Settle detection (render thread)

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        guard gate.isSimulating else { return }
        if rollStart < 0 { rollStart = time }

        let allResting = dice.allSatisfy { die in
            guard let body = die.node.physicsBody else { return true }
            let v = body.velocity
            let speed = sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
            return speed < 0.15 && abs(body.angularVelocity.w) < 0.3
        }
        stableFrames = allResting ? stableFrames + 1 : 0
        if stableFrames > 30 || time - rollStart > rollTimeout {
            gate.setSimulating(false)
            // Freeze every die exactly where it is — whether settling was detected
            // normally or we hit the timeout — so nothing keeps drifting/jittering
            // once the total is on screen.
            freezeDice()
            let settled = computeResults()
            DispatchQueue.main.async {
                self.results = settled
                self.phase = .settled
                // Nothing moves from here on, so let the frozen frame reach the
                // screen and then stop rendering.
                self.requestRedraw()
            }
        }
    }

    /// Locks every die's current rendered transform onto the node itself and takes
    /// it out of the physics simulation, so it can no longer move or jitter.
    private func freezeDice() {
        for die in dice {
            let node = die.node
            node.position = node.presentation.position
            node.orientation = node.presentation.orientation
            node.physicsBody?.velocity = SCNVector3Zero
            node.physicsBody?.angularVelocity = SCNVector4Zero
            node.physicsBody?.type = .kinematic
            // A settled pile rests in permanent mutual contact, so leaving
            // reporting on means a stream of physics-thread callbacks for a state
            // that can no longer produce a sound. `spawn` sets the mask afresh
            // next roll.
            node.physicsBody?.contactTestBitMask = 0
        }
    }

    private func computeResults() -> [RollResult] {
        let up = simd_float3(0, 1, 0)
        var res = dice.map { die -> RollResult in
            let q = die.node.presentation.simdOrientation
            if die.model.type == .d4 {
                // d4 is read from the number at the apex (upward-pointing) vertex.
                let apex = die.model.vertexValues.max { a, b in
                    simd_act(q, a.position).y < simd_act(q, b.position).y
                }!
                return RollResult(type: .d4, value: apex.value)
            }
            // Everything else: read the top face.
            let best = die.model.faces.max { a, b in
                simd_dot(simd_act(q, a.normal), up) < simd_dot(simd_act(q, b.normal), up)
            }!
            return RollResult(type: die.model.type, value: best.value)
        }
        res.sort { a, b in
            if a.type != b.type { return a.type.rawValue < b.type.rawValue }
            return a.value > b.value
        }
        return res
    }
}
