import SwiftUI

struct ContentView: View {
    @StateObject private var controller = DiceController()
    @StateObject private var prefs = Preferences.shared
    @State private var showPreferences = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            DiceSceneView(controller: controller, shaderStyle: prefs.shaderStyle)
                .ignoresSafeArea()
            if showPreferences {
                // Tapping anywhere off the panel dismisses it. Every setting is
                // written through its binding as it changes, so there's nothing
                // to commit on the way out.
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture { showPreferences = false }
            }
            VStack(spacing: 12) {
                if controller.phase == .settled && !showPreferences {
                    ResultsBar(results: controller.results)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
                bottomPanel
            }
            .padding(16)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: controller.phase)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: showPreferences)
        // Liquid Glass materials can render with a stale environment when a view
        // is first inserted via an animated transition (e.g. the settled-state
        // buttons appearing) — explicitly re-asserting the scheme here forces
        // them to use the real, current one instead of momentarily defaulting.
        .environment(\.colorScheme, colorScheme)
    }

    @ViewBuilder
    private var bottomPanel: some View {
        if showPreferences {
            PreferencesPanel(prefs: prefs) { showPreferences = false }
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else {
            switch controller.phase {
            case .picking:
                DicePickerPanel(controller: controller)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            case .rolling:
                EmptyView()
            case .settled:
                HStack(spacing: 8) {
                    Button {
                        controller.roll()
                    } label: {
                        Text("Roll Again")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    Button {
                        controller.phase = .picking
                    } label: {
                        Text("Change Dice")
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular, in: Capsule())
                    Button {
                        showPreferences = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 48, height: 48)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular, in: Circle())
                    .accessibilityLabel("Preferences")
                }
                .frame(maxWidth: 420)
                .transition(.opacity)
            }
        }
    }
}

struct DicePickerPanel: View {
    @ObservedObject var controller: DiceController

    var body: some View {
        VStack(spacing: 4) {
            Text("Select your dice")
                .font(.title.weight(.bold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 6)
            ForEach(DieType.allCases) { type in
                HStack {
                    DieIcon(spec: DieIconSpec.spec(for: type))
                        .frame(width: 20, height: 20)
                    Text(type.displayName)
                        .font(.body.weight(.semibold))
                    Spacer()
                    Text("\((controller.counts[type] ?? 0))")
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(controller.counts[type] ?? 0)))
                        .foregroundStyle((controller.counts[type] ?? 0) > 0 ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                        .frame(minWidth: 24, alignment: .trailing)
                        .animation(.easeInOut(duration: 0.25), value: controller.counts[type] ?? 0)
                    // Upper bound is this die's own count plus whatever headroom is
                    // left across all dice, so once the shared max is reached every
                    // stepper's own "+" disables itself automatically — including
                    // dice that already have a non-zero count.
                    Stepper("", value: binding(for: type), in: 0...maxAllowed(for: type))
                        .labelsHidden()
                        .animation(.easeInOut(duration: 0.2), value: maxAllowed(for: type))
                }
                .padding(.vertical, 2)
            }
            Button {
                controller.roll()
            } label: {
                Text(buttonTitle)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .contentTransition(.opacity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(controller.totalCount == 0)
            .animation(.easeInOut(duration: 0.2), value: controller.totalCount == 0)
            .padding(.top, 12)
        }
        .padding(18)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .frame(maxWidth: 420)
    }

    private var buttonTitle: String {
        let n = controller.totalCount
        guard n > 0 else { return "Choose at least one" }
        return "Roll \(n) \(n == 1 ? "die" : "dice")"
    }

    /// The highest this die's own count could reach without the grand total
    /// exceeding maxDice, given every OTHER die type's current count. At the
    /// shared cap this equals `current` for every type (zero or not), so every
    /// stepper's "+" disables uniformly — the earlier version accidentally added
    /// `current` on top of an already-current-inclusive bound, which is why dice
    /// with a non-zero count kept a phantom extra allowance instead of capping.
    private func maxAllowed(for type: DieType) -> Int {
        let current = controller.counts[type] ?? 0
        let others = controller.totalCount - current
        return max(current, DiceController.maxDice - others)
    }

    private func binding(for type: DieType) -> Binding<Int> {
        Binding(
            get: { controller.counts[type] ?? 0 },
            set: { newValue in
                controller.counts[type] = max(0, min(newValue, maxAllowed(for: type)))
            }
        )
    }
}

struct PreferencesPanel: View {
    @ObservedObject var prefs: Preferences
    var onDone: () -> Void

    var body: some View {
        // Horizontal insets are applied per-section rather than to the whole
        // stack so the shader strip can scroll edge to edge under the panel's
        // padding once there are more styles than fit across.
        VStack(alignment: .leading, spacing: 0) {
            Toggle("Dice go click clack", isOn: $prefs.soundEnabled)
                .font(.body.weight(.semibold))
                .padding(.horizontal, 18)

            Text("SHADER")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 8)

            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(ShaderStyle.allCases) { style in
                        ShaderThumbnail(style: style, isSelected: prefs.shaderStyle == style) {
                            prefs.shaderStyle = style
                        }
                    }
                }
                .padding(.vertical, 3)
            }
            .contentMargins(.horizontal, 18, for: .scrollContent)
            .scrollIndicators(.hidden)

            Button(action: onDone) {
                Text("Done")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .padding(.horizontal, 18)
            .padding(.top, 18)
        }
        .padding(.vertical, 18)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        // The glass background itself isn't hit-testable, so without this a tap on
        // the panel's own empty space falls through to the dismiss layer behind it
        // and closes the panel. Controls inside still win the gesture.
        .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .onTapGesture {}
        .frame(maxWidth: 420)
    }
}

/// One shader option, previewed with the look's own thumbnail image.
struct ShaderThumbnail: View {
    let style: ShaderStyle
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(style.thumbnailImageName)
                .resizable()
                .scaledToFill()
                .frame(width: 78, height: 78)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.tint, lineWidth: 3)
                        .opacity(isSelected ? 1 : 0)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(style.displayName)
        .animation(.easeInOut(duration: 0.2), value: isSelected)
    }
}

struct ResultsBar: View {
    let results: [RollResult]

    // Persists across rolls AND app launches, per-preference, via UserDefaults.
    @AppStorage("resultsPanelExpanded") private var isExpanded = false

    private var total: Int { results.reduce(0) { $0 + $1.value } }
    private var highest: Int { results.map(\.value).max() ?? 0 }
    private var showHighest: Bool { results.count > 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 28) {
                stat("Total", total)
                if showHighest {
                    stat("Highest", highest)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 30, height: 30)
            }
            if isExpanded {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 68), spacing: 6)],
                         alignment: .leading, spacing: 6) {
                    ForEach(results) { result in
                        HStack(spacing: 4) {
                            Text(result.type.displayName)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            Text("\(result.value)")
                                .font(.callout.weight(.semibold))
                                .monospacedDigit()
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 10)
                        .background(.quaternary, in: Capsule())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
            }
        }
        .padding(16)
        .frame(maxWidth: 420)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                isExpanded.toggle()
            }
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isExpanded)
    }

    private func stat(_ label: String, _ value: Int) -> some View {
        VStack(spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(value)")
                .font(.system(size: 45, weight: .bold))
                .monospacedDigit()
        }
    }
}

/// Flat, rounded-corner regular polygon used as a quick-glance die icon.
/// `pointsUp` picks the base orientation: true puts a vertex exactly at the top
/// (diamonds, the D12 hexagon); false offsets by half a step so the shape sits
/// flat-side-up instead (the D6 square, the base D4 triangle before rotation).
/// `aspectX`/`aspectY` stretch it non-uniformly to make diamond shapes.
struct RoundedPolygon: Shape {
    var sides: Int
    var cornerRadius: CGFloat
    var pointsUp: Bool = false
    var aspectX: CGFloat = 1
    var aspectY: CGFloat = 1

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let angleStep = 2 * CGFloat.pi / CGFloat(sides)
        let startAngle = pointsUp ? -CGFloat.pi / 2 : -CGFloat.pi / 2 + angleStep / 2

        let vertices = (0..<sides).map { i -> CGPoint in
            let angle = startAngle + angleStep * CGFloat(i)
            return CGPoint(x: center.x + radius * aspectX * cos(angle),
                           y: center.y + radius * aspectY * sin(angle))
        }
        let rc = min(cornerRadius, radius * min(aspectX, aspectY) * 0.4)

        var path = Path()
        for i in 0..<sides {
            let curr = vertices[i]
            let prev = vertices[(i - 1 + sides) % sides]
            let next = vertices[(i + 1) % sides]
            let toPrev = normalized(CGPoint(x: prev.x - curr.x, y: prev.y - curr.y))
            let toNext = normalized(CGPoint(x: next.x - curr.x, y: next.y - curr.y))
            let a = CGPoint(x: curr.x + toPrev.x * rc, y: curr.y + toPrev.y * rc)
            let b = CGPoint(x: curr.x + toNext.x * rc, y: curr.y + toNext.y * rc)
            if i == 0 { path.move(to: a) } else { path.addLine(to: a) }
            path.addQuadCurve(to: b, control: curr)
        }
        path.closeSubpath()
        return path
    }

    private func normalized(_ p: CGPoint) -> CGPoint {
        let len = max(0.0001, (p.x * p.x + p.y * p.y).squareRoot())
        return CGPoint(x: p.x / len, y: p.y / len)
    }
}

/// Per-die icon shape. Sides/orientation/aspect describe a quick-glance icon,
/// not a literal model of each die's real face geometry.
struct DieIconSpec {
    var sides: Int
    var pointsUp: Bool = false
    var aspectX: CGFloat = 1
    var aspectY: CGFloat = 1
    var rotationDegrees: Double = 0
    var yOffset: CGFloat = 0

    static func spec(for type: DieType) -> DieIconSpec {
        switch type {
        case .d4:
            // Base triangle sits point-down; rotate 180° to point up. A
            // triangle's centroid sits below its bounding-box center, so nudge
            // it down a touch to look visually centered against the other icons.
            return DieIconSpec(sides: 3, rotationDegrees: 180, yOffset: 1.5)
        case .d6:
            return DieIconSpec(sides: 4)
        case .d8:
            // Tall diamond.
            return DieIconSpec(sides: 4, pointsUp: true, aspectX: 0.87, aspectY: 1.08)
        case .d10:
            // Wide diamond.
            return DieIconSpec(sides: 4, pointsUp: true, aspectX: 1.08, aspectY: 0.87)
        case .d12:
            // Same hexagon as D20, rotated 90°.
            return DieIconSpec(sides: 6, pointsUp: true, rotationDegrees: 90)
        case .d20:
            // Hexagon, vertex at top.
            return DieIconSpec(sides: 6, pointsUp: true)
        }
    }
}

struct DieIcon: View {
    let spec: DieIconSpec
    @Environment(\.colorScheme) private var colorScheme

    private var fillColor: Color {
        colorScheme == .dark ? Color(white: 0.82) : Color(white: 0.42)
    }

    var body: some View {
        RoundedPolygon(sides: spec.sides, cornerRadius: 2.2,
                      pointsUp: spec.pointsUp, aspectX: spec.aspectX, aspectY: spec.aspectY)
            .fill(fillColor)
            .rotationEffect(.degrees(spec.rotationDegrees))
            .offset(y: spec.yOffset)
    }
}

#Preview {
    ContentView()
}
