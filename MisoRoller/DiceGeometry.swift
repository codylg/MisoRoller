import SceneKit
import UIKit
import simd

enum DieType: Int, CaseIterable, Identifiable {
    case d4 = 4, d6 = 6, d8 = 8, d10 = 10, d12 = 12, d20 = 20

    var id: Int { rawValue }
    var sides: Int { rawValue }
    var displayName: String { "D\(rawValue)" }

    var circumradius: Float {
        switch self {
        case .d4: return 1.03    // +5% again (was 0.98)
        case .d6: return 1.05
        case .d8: return 1.0
        case .d10: return 0.95
        case .d12: return 0.95
        case .d20: return 1.05
        }
    }
}

struct DieFace {
    let normal: simd_float3
    let value: Int
}

struct DieModel {
    let type: DieType
    let geometry: SCNGeometry
    let faces: [DieFace]
    /// d4 only: each vertex's local position and the number printed at it. The
    /// rolled value is the number at the upward-pointing (apex) vertex.
    var vertexValues: [(position: simd_float3, value: Int)] = []
}

enum DiceGeometry {
    private static var cache: [DieType: DieModel] = [:]
    private static var shapeCache: [DieType: SCNPhysicsShape] = [:]

    static func model(for type: DieType) -> DieModel {
        if let cached = cache[type] { return cached }
        let model = build(type)
        cache[type] = model
        return model
    }

    /// The collision shape for a die type, built once and shared by every die of
    /// that type. `SCNPhysicsShape` is immutable, so one instance can back any
    /// number of bodies — and it has to be shared, because hulling the beveled
    /// mesh (a few hundred triangles for a d20) up to `maxDice` times was
    /// happening synchronously on the main thread at the exact moment a roll
    /// starts, which is the worst possible place for it.
    static func physicsShape(for type: DieType) -> SCNPhysicsShape {
        if let cached = shapeCache[type] { return cached }
        let shape = SCNPhysicsShape(geometry: model(for: type).geometry,
                                    options: [.type: SCNPhysicsShape.ShapeType.convexHull])
        shapeCache[type] = shape
        return shape
    }

    private static let phi = Float((1.0 + sqrt(5.0)) / 2.0)
    private static let bevel: Float = 0.08

    private static func vertices(for type: DieType) -> [simd_float3] {
        switch type {
        case .d4:
            return [[1, 1, 1], [1, -1, -1], [-1, 1, -1], [-1, -1, 1]]
        case .d6:
            var v: [simd_float3] = []
            for x: Float in [-1, 1] {
                for y: Float in [-1, 1] {
                    for z: Float in [-1, 1] { v.append([x, y, z]) }
                }
            }
            return v
        case .d8:
            return [[1, 0, 0], [-1, 0, 0], [0, 1, 0], [0, -1, 0], [0, 0, 1], [0, 0, -1]]
        case .d10:
            // Pentagonal trapezohedron: zigzag equator ring plus two apexes,
            // apex height solved so each kite face is planar. Amplitude tuned
            // so the apex-to-apex height roughly matches the ring diameter,
            // like a real d10 (rather than the tall spike a bigger amplitude gives).
            let c: Float = 0.11
            var ring: [simd_float3] = []
            for j in 0..<10 {
                let angle = Float(j) * .pi / 5
                ring.append([cos(angle), j % 2 == 0 ? c : -c, sin(angle)])
            }
            let p1 = ring[0], p2 = ring[1], p3 = ring[2]
            let n = simd_cross(p2 - p1, p3 - p1)
            let apexY = abs(p1.y + (n.x * p1.x + n.z * p1.z) / n.y)
            return ring + [[0, apexY, 0], [0, -apexY, 0]]
        case .d12:
            let a = 1 / phi, b = phi
            var v: [simd_float3] = []
            for x: Float in [-1, 1] {
                for y: Float in [-1, 1] {
                    for z: Float in [-1, 1] { v.append([x, y, z]) }
                }
            }
            v += [[0, a, b], [0, a, -b], [0, -a, b], [0, -a, -b],
                  [a, b, 0], [a, -b, 0], [-a, b, 0], [-a, -b, 0],
                  [b, 0, a], [b, 0, -a], [-b, 0, a], [-b, 0, -a]]
            return v
        case .d20:
            return [[0, 1, phi], [0, 1, -phi], [0, -1, phi], [0, -1, -phi],
                    [1, phi, 0], [1, -phi, 0], [-1, phi, 0], [-1, -phi, 0],
                    [phi, 0, 1], [phi, 0, -1], [-phi, 0, 1], [-phi, 0, -1]]
        }
    }

    /// Brute-force convex hull: every supporting plane of the vertex cloud is a face.
    /// Fine at this scale (max 20 vertices) and avoids hardcoding face indices.
    /// Faces are returned as indices into `verts` (not raw positions) so edges and
    /// vertex fans can be identified for beveling.
    private static func hullFaces(_ verts: [simd_float3]) -> [(normal: simd_float3, indices: [Int])] {
        var faces: [(normal: simd_float3, indices: [Int])] = []
        var seenNormals: [simd_float3] = []
        let count = verts.count
        let eps: Float = 1e-4

        for i in 0..<count {
            for j in (i + 1)..<count {
                for k in (j + 1)..<count {
                    var n = simd_cross(verts[j] - verts[i], verts[k] - verts[i])
                    let len = simd_length(n)
                    if len < 1e-6 { continue }
                    n /= len
                    var d = simd_dot(n, verts[i])
                    if d < 0 { n = -n; d = -d }
                    if verts.contains(where: { simd_dot($0, n) > d + eps }) { continue }
                    if seenNormals.contains(where: { simd_dot($0, n) > 1 - 1e-5 }) { continue }
                    seenNormals.append(n)
                    let idxs = (0..<count).filter { simd_dot(verts[$0], n) > d - eps }
                    faces.append((n, sortIndicesAroundNormal(idxs, verts, n)))
                }
            }
        }
        return faces
    }

    private static func sortIndicesAroundNormal(_ idxs: [Int], _ verts: [simd_float3], _ n: simd_float3) -> [Int] {
        let pts = idxs.map { verts[$0] }
        let c = pts.reduce(simd_float3(), +) / Float(pts.count)
        let u = simd_normalize(pts[0] - c)
        let v = simd_cross(n, u)
        func angle(_ i: Int) -> Float {
            let p = verts[i]
            return atan2(simd_dot(p - c, v), simd_dot(p - c, u))
        }
        return idxs.sorted { angle($0) < angle($1) }
    }

    /// Pair opposite faces so they sum to sides + 1, like real dice.
    private static func assignValues(_ normals: [simd_float3]) -> [Int] {
        let count = normals.count
        if count == 4 { return [1, 2, 3, 4] }
        var values = [Int](repeating: 0, count: count)
        var assigned = [Bool](repeating: false, count: count)
        var low = 1, high = count
        for i in 0..<count where !assigned[i] {
            assigned[i] = true
            values[i] = low
            low += 1
            if let j = (0..<count).first(where: { !assigned[$0] && simd_dot(normals[$0], normals[i]) < -0.999 }) {
                assigned[j] = true
                values[j] = high
                high -= 1
            }
        }
        return values
    }

    private static func edgeKey(_ a: Int, _ b: Int) -> UInt64 {
        UInt64(min(a, b)) << 32 | UInt64(max(a, b))
    }

    private static func build(_ type: DieType) -> DieModel {
        var verts = vertices(for: type)
        let maxLen = verts.map(simd_length).max() ?? 1
        let scale = type.circumradius / maxLen
        verts = verts.map { $0 * scale }

        let faces = hullFaces(verts)
        assert(faces.count == type.sides, "expected \(type.sides) faces, got \(faces.count)")
        let values = assignValues(faces.map(\.normal))

        // d4: number the four vertices (1...4) rather than the faces. Each face
        // then prints the numbers of its three corner vertices, and the roll is
        // read from the apex vertex.
        let vertexNumbers: [Int] = type == .d4 ? Array(1...verts.count) : []

        // Each face is inset toward its own centroid by `bevel`, opening a thin gap
        // along every edge and at every vertex. Those gaps are filled with a plain
        // rim material, giving the die a slightly rounded/chamfered look without
        // needing true rounded geometry.
        var faceCentroids: [simd_float3] = []
        var faceInsets: [[simd_float3]] = []
        for face in faces {
            let pts = face.indices.map { verts[$0] }
            let c = pts.reduce(simd_float3(), +) / Float(pts.count)
            faceCentroids.append(c)
            faceInsets.append(pts.map { c + ($0 - c) * (1 - bevel) })
        }

        var positions: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var uvs: [CGPoint] = []
        var elements: [SCNGeometryElement] = []
        var materials: [SCNMaterial] = []
        var faceInfos: [DieFace] = []

        // Core (inset) faces, numbered.
        for (fi, face) in faces.enumerated() {
            let pts = face.indices.map { verts[$0] }
            let insetPts = faceInsets[fi]
            let n = face.normal
            let c = faceCentroids[fi]
            // Orient every face's numeral consistently: its "up" is a fixed world
            // reference (Y, or Z for near-horizontal faces) projected onto the face
            // plane — not an arbitrary vertex direction, which tilted each number by
            // a different amount (a square's vertex sits 45° off its edges).
            var upRef = simd_float3(0, 1, 0)
            if abs(simd_dot(upRef, n)) > 0.99 { upRef = simd_float3(0, 0, 1) }
            let up = simd_normalize(upRef - simd_dot(upRef, n) * n)
            let right = simd_cross(up, n)          // image right (matches non-mirrored handedness)
            let ext = (pts.map { max(abs(simd_dot($0 - c, right)), abs(simd_dot($0 - c, up))) }.max() ?? 1) * 1.3
            let base = Int32(positions.count)

            for p in insetPts {
                positions.append(SCNVector3(p.x, p.y, p.z))
                normals.append(SCNVector3(n.x, n.y, n.z))
                uvs.append(CGPoint(x: CGFloat(0.5 + simd_dot(p - c, right) / (2 * ext)),
                                   y: CGFloat(0.5 - simd_dot(p - c, up) / (2 * ext))))
            }
            var indices: [Int32] = []
            for t in 1..<(insetPts.count - 1) {
                indices += [base, base + Int32(t), base + Int32(t + 1)]
            }
            elements.append(SCNGeometryElement(indices: indices, primitiveType: .triangles))
            if type == .d4 {
                // Each corner shows its vertex's number, positioned/rotated toward
                // that vertex so it reads upright when that vertex points up.
                let corners = face.indices.map { vi -> (value: Int, uv: CGPoint) in
                    let p = verts[vi]
                    let uv = CGPoint(x: CGFloat(0.5 + simd_dot(p - c, right) / (2 * ext)),
                                     y: CGFloat(0.5 - simd_dot(p - c, up) / (2 * ext)))
                    return (vertexNumbers[vi], uv)
                }
                materials.append(DieFaceMaterials.d4FaceMaterial(corners: corners))
            } else {
                materials.append(DieFaceMaterials.material(value: values[fi], sides: type.sides))
            }
            faceInfos.append(DieFace(normal: n, value: values[fi]))
        }

        let rimMaterial = SCNMaterial()
        rimMaterial.diffuse.contents = DieFaceMaterials.paperColor
        rimMaterial.lightingModel = .blinn
        rimMaterial.specular.contents = UIColor(white: 0.3, alpha: 1)
        // Single-sided on purpose. This was double-sided, which papered over the
        // inward-wound bevel quads below and turned a would-be hole into a subtly
        // wrong shade instead — a much harder bug to see. With correct winding it
        // buys nothing on a convex solid, and any future regression now shows up
        // as an obvious gap rather than a mysteriously dark edge.
        rimMaterial.isDoubleSided = false

        // Edge bevel strips: for every edge shared by two faces, connect their
        // (now separated) inset boundaries.
        //
        // Each strip is split down the middle into two quads, one per face, and
        // each carries its own face's normal flat across it. The obvious
        // alternative — one quad blending from face A's normal to face B's — is
        // what made every edge read as a distinct darker grey line: the strips are
        // only a few pixels wide on screen, so you never see the gradient, only
        // its middle, and the average of two face normals is always angled further
        // from the light than the brighter of the two. Flat-shading each half
        // instead lets each face's tone run right up to the crease, so the rim
        // disappears into the surface it borders while the geometry (and so the
        // rounded silhouette and the physics) is unchanged.
        var edgeMap: [UInt64: [(face: Int, pos: Int)]] = [:]
        for (fi, face) in faces.enumerated() {
            let n = face.indices.count
            for t in 0..<n {
                let key = edgeKey(face.indices[t], face.indices[(t + 1) % n])
                edgeMap[key, default: []].append((fi, t))
            }
        }

        var bevelIndices: [Int32] = []
        for (_, occurrences) in edgeMap {
            guard occurrences.count == 2 else { continue }
            let (fA, tA) = occurrences[0]
            let (fB, _) = occurrences[1]
            let faceA = faces[fA], faceB = faces[fB]
            let nA = faceA.indices.count
            let aI = faceA.indices[tA]
            let aJ = faceA.indices[(tA + 1) % nA]
            guard let posBI = faceB.indices.firstIndex(of: aI),
                  let posBJ = faceB.indices.firstIndex(of: aJ) else { continue }

            let Ai = faceInsets[fA][tA]
            let Aj = faceInsets[fA][(tA + 1) % nA]
            let Bi = faceInsets[fB][posBI]
            let Bj = faceInsets[fB][posBJ]

            // The crease down the centre of the strip, where the two halves meet.
            let Mi = (Ai + Bi) * 0.5
            let Mj = (Aj + Bj) * 0.5

            for (corners, n) in [([Ai, Aj, Mj, Mi], faceA.normal), ([Mi, Mj, Bj, Bi], faceB.normal)] {
                // Wind the quad so its front face points outward. Taking the ring
                // in edge order (A's boundary, then across to B's) produces an
                // INWARD-facing quad — see the cube derivation: for A=+Y, B=+X the
                // geometric normal comes out (-1,-1,0). That was the real reason
                // every edge looked like a darker material: `isDoubleSided` hid the
                // resulting hole, but a back-facing fragment gets its shading normal
                // flipped, so `dot(N, L)` clamped to zero and every strip rendered
                // at ambient only — uniformly dark, and unresponsive to how the die
                // was oriented, which is exactly how a darker *material* reads.
                let geometric = simd_cross(corners[1] - corners[0], corners[2] - corners[0])
                let ring = simd_dot(geometric, n) < 0 ? Array(corners.reversed()) : corners

                let base = Int32(positions.count)
                for p in ring {
                    positions.append(SCNVector3(p.x, p.y, p.z))
                    normals.append(SCNVector3(n.x, n.y, n.z))
                }
                uvs.append(contentsOf: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
                                        CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)])
                bevelIndices += [base, base + 1, base + 2, base, base + 2, base + 3]
            }
        }
        if !bevelIndices.isEmpty {
            elements.append(SCNGeometryElement(indices: bevelIndices, primitiveType: .triangles))
            materials.append(rimMaterial)
        }

        // Vertex caps: at each original vertex, fan-triangulate the small gap left
        // between the edge-bevel corners of every face that met there, using the
        // outward radial direction as the normal for a rounded-corner highlight.
        var vertexFaceInsets: [Int: [(face: Int, pos: simd_float3)]] = [:]
        for (fi, face) in faces.enumerated() {
            for (li, vi) in face.indices.enumerated() {
                vertexFaceInsets[vi, default: []].append((fi, faceInsets[fi][li]))
            }
        }
        var capIndices: [Int32] = []
        for (vi, entries) in vertexFaceInsets where entries.count >= 3 {
            let v = verts[vi]
            let radial = simd_normalize(v)
            var tangent = simd_cross(radial, simd_float3(0, 1, 0))
            if simd_length(tangent) < 1e-4 { tangent = simd_cross(radial, simd_float3(1, 0, 0)) }
            tangent = simd_normalize(tangent)
            let bitangent = simd_cross(radial, tangent)
            func angleOf(_ p: simd_float3) -> Float {
                let d = p - v
                return atan2(simd_dot(d, bitangent), simd_dot(d, tangent))
            }
            var sorted = entries.sorted { angleOf($0.pos) < angleOf($1.pos) }
            // Same outward-winding guard as the bevel strips: the fan has to face
            // out, or it renders as a hole now that the rim is single-sided.
            let fanNormal = simd_cross(sorted[1].pos - sorted[0].pos, sorted[2].pos - sorted[0].pos)
            if simd_dot(fanNormal, radial) < 0 { sorted.reverse() }

            let capCenter = v * (1 - bevel)
            let base = Int32(positions.count)
            positions.append(SCNVector3(capCenter.x, capCenter.y, capCenter.z))
            normals.append(SCNVector3(radial.x, radial.y, radial.z))
            uvs.append(CGPoint(x: 0.5, y: 0.5))
            // Ring vertices take the normal of the face they came from, for the
            // same reason the edge strips do — a cap shaded entirely by its radial
            // reads as a grey speck against the faces around it. Only the centre
            // stays radial, which leaves a soft rounded glint on the corner itself.
            for e in sorted {
                positions.append(SCNVector3(e.pos.x, e.pos.y, e.pos.z))
                let fn = faces[e.face].normal
                normals.append(SCNVector3(fn.x, fn.y, fn.z))
                uvs.append(CGPoint(x: 0.5, y: 0.5))
            }
            let n = sorted.count
            for t in 0..<n {
                capIndices += [base, base + 1 + Int32(t), base + 1 + Int32((t + 1) % n)]
            }
        }
        if !capIndices.isEmpty {
            elements.append(SCNGeometryElement(indices: capIndices, primitiveType: .triangles))
            materials.append(rimMaterial)
        }

        let geometry = SCNGeometry(
            sources: [
                SCNGeometrySource(vertices: positions),
                SCNGeometrySource(normals: normals),
                SCNGeometrySource(textureCoordinates: uvs)
            ],
            elements: elements
        )
        geometry.materials = materials
        let vertexData: [(position: simd_float3, value: Int)] = type == .d4
            ? (0..<verts.count).map { (verts[$0], vertexNumbers[$0]) }
            : []
        return DieModel(type: type, geometry: geometry, faces: faceInfos, vertexValues: vertexData)
    }
}

enum DieFaceMaterials {
    private static var cache: [String: SCNMaterial] = [:]

    static let paperColor = UIColor(red: 1.0, green: 0.98, blue: 0.93, alpha: 1)
    static let inkColor = UIColor(red: 0.13, green: 0.10, blue: 0.08, alpha: 1)

    static func material(value: Int, sides: Int) -> SCNMaterial {
        let key = "\(sides)-\(value)"
        if let m = cache[key] { return m }
        let m = SCNMaterial()
        m.diffuse.contents = faceImage(value: value, sides: sides, dotted: value == 6 || value == 9)
        m.lightingModel = .blinn
        m.specular.contents = UIColor(white: 0.3, alpha: 1)
        cache[key] = m
        return m
    }

    /// A d4 face: three numbers, one per corner, each rotated to point toward its
    /// vertex. Not cached — every face has a distinct set of corner numbers.
    static func d4FaceMaterial(corners: [(value: Int, uv: CGPoint)]) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = d4FaceImage(corners: corners)
        m.lightingModel = .blinn
        m.specular.contents = UIColor(white: 0.3, alpha: 1)
        return m
    }

    private static func d4FaceImage(corners: [(value: Int, uv: CGPoint)]) -> UIImage {
        let side: CGFloat = 256
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        return renderer.image { ctx in
            paperColor.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))

            let cg = ctx.cgContext
            let fontSize: CGFloat = 68 * 0.9
            let font = UIFont(descriptor: UIFont.systemFont(ofSize: fontSize, weight: .semibold)
                .fontDescriptor.withDesign(.rounded) ?? UIFont.systemFont(ofSize: fontSize).fontDescriptor,
                              size: fontSize)
            let center = CGPoint(x: side / 2, y: side / 2)
            for corner in corners {
                let cp = CGPoint(x: corner.uv.x * side, y: corner.uv.y * side)
                let dir = CGPoint(x: cp.x - center.x, y: cp.y - center.y)   // toward the vertex (y-down)
                let pos = CGPoint(x: center.x + dir.x * 0.52, y: center.y + dir.y * 0.52)
                let angle = atan2(dir.x, -dir.y)   // rotate so the digit's top points at the vertex
                let text = NSAttributedString(string: "\(corner.value)",
                                              attributes: [.font: font, .foregroundColor: inkColor])
                let b = text.boundingRect(with: CGSize(width: side, height: side),
                                          options: .usesLineFragmentOrigin, context: nil)
                cg.saveGState()
                cg.translateBy(x: pos.x, y: pos.y)
                cg.rotate(by: angle)
                text.draw(at: CGPoint(x: -b.width / 2, y: -b.height / 2))
                cg.restoreGState()
            }
        }
    }

    /// Numeral size relative to the base font, tuned per die so numbers sit
    /// comfortably inside each face shape.
    private static func numeralScale(forSides sides: Int) -> CGFloat {
        switch sides {
        case 6:  return 0.96    // 0.80 increased 20%
        case 12: return 0.80    // 1.00 reduced 20%
        case 8:  return 0.624   // 0.78 reduced 20%
        case 10: return 0.491   // 0.546 reduced 10%
        case 20: return 0.702   // 0.78 reduced 10%
        default: return 0.78    // D4
        }
    }

    private static func faceImage(value: Int, sides: Int, dotted: Bool) -> UIImage {
        let side: CGFloat = 256
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        return renderer.image { ctx in
            paperColor.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))

            let fontSize: CGFloat = (value >= 10 ? 104 : 128) * numeralScale(forSides: sides)
            let baseFont = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
            let descriptor = baseFont.fontDescriptor.withDesign(.rounded) ?? baseFont.fontDescriptor
            let font = UIFont(descriptor: descriptor, size: fontSize)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: inkColor]
            let text = NSAttributedString(string: "\(value)", attributes: attrs)
            let bounds = text.boundingRect(with: CGSize(width: side, height: side),
                                           options: .usesLineFragmentOrigin, context: nil)
            let origin = CGPoint(x: (side - bounds.width) / 2, y: (side - bounds.height) / 2)
            text.draw(at: origin)

            if dotted {
                // Disambiguation full stop (e.g. "6." vs "9"). ~20% smaller than
                // the digit and drawn after/independent of the centering math, so
                // the digit itself never shifts whether or not the dot is present.
                let dotSize = fontSize * 0.8
                let dotBase = UIFont.systemFont(ofSize: dotSize, weight: .semibold)
                let dotDesc = dotBase.fontDescriptor.withDesign(.rounded) ?? dotBase.fontDescriptor
                let dotFont = UIFont(descriptor: dotDesc, size: dotSize)
                let dot = NSAttributedString(string: ".", attributes: [.font: dotFont, .foregroundColor: inkColor])
                // Sit the smaller dot on the digit's baseline (align ascenders).
                let dotX = origin.x + bounds.width * 0.80
                let dotY = origin.y + (font.ascender - dotFont.ascender)
                dot.draw(at: CGPoint(x: dotX, y: dotY))
            }
        }
    }
}
