import SwiftUI
import SceneKit
import UIKit

final class LayoutReportingSCNView: SCNView {
    var onLayout: ((CGSize) -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?(bounds.size)
    }
}

/// Keeps the dice table locked against interface rotation while still tracking
/// this view's own real size. It's a top-down view of a table, so it has no
/// inherent "up" — turning the device shouldn't turn, reshape or rescale it —
/// but on iPad it can genuinely be given less space (Split View, Stage Manager),
/// and the table has to fit that or the dice roll off the visible area. Only the
/// SwiftUI chrome rotates; the table both stays upright AND fits its window.
///
/// Staying put takes an active counter-rotation rather than no transform at all:
/// UIKit rotates the whole view hierarchy for interface orientation, so a subview
/// that does nothing is carried around with it.
final class ScreenLockedContainer: UIView {
    let sceneView = LayoutReportingSCNView(frame: .zero)

    /// Holds a synchronously-rendered first frame so the table is on screen from
    /// the very first UIKit commit.
    ///
    /// An SCNView presents nothing until its own display link runs, which is
    /// several frames after the rest of the UI has already been committed — and
    /// until then its Metal layer is empty, so the window's plain background
    /// shows straight through it. That white flash, followed by the real scene
    /// arriving, is what read as the shader "popping in" a moment after launch.
    /// Rendering one frame by hand during the first layout pass fills the gap
    /// with exactly what the scene is about to draw anyway, so there's nothing
    /// left to change appearance.
    private let firstFrameView = UIImageView()
    private var hasCapturedFirstFrame = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        firstFrameView.contentMode = .scaleToFill
        addSubview(firstFrameView)
        addSubview(sceneView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Measure the rotation the interface has imposed on us rather than
        // assuming which way each orientation turns: send a unit vector into the
        // screen's fixed, unturning coordinate space and read back the angle it
        // arrives at. Undoing that angle leaves the scene square to the physical
        // display — and it's self-correcting, so there's no sign to get wrong.
        let space = (window?.screen ?? UIScreen.main).fixedCoordinateSpace
        let origin = convert(CGPoint.zero, to: space)
        let unitX = convert(CGPoint(x: 1, y: 0), to: space)
        let angle = atan2(unitX.y - origin.y, unitX.x - origin.x)

        // Size from THIS view's own bounds, not the screen's — on iPad the
        // window can be smaller than the display, and the table needs to fit
        // whatever space it's actually been given rather than always the full
        // screen. Interface rotation is always an exact quarter turn, so
        // de-rotating just means swapping width/height back out for a 90°/270°
        // turn — that's what keeps the table's own shape constant across
        // rotation while still tracking a live window resize.
        let raw = bounds.size
        let quarterTurns = Int((angle / (.pi / 2)).rounded())
        let isQuarterTurn = quarterTurns % 2 != 0
        let nativeSize = isQuarterTurn ? CGSize(width: raw.height, height: raw.width) : raw

        sceneView.bounds = CGRect(origin: .zero, size: nativeSize)
        sceneView.transform = CGAffineTransform(rotationAngle: -angle)
        sceneView.center = CGPoint(x: bounds.midX, y: bounds.midY)

        firstFrameView.bounds = sceneView.bounds
        firstFrameView.transform = sceneView.transform
        firstFrameView.center = sceneView.center
        captureFirstFrameIfNeeded()
    }

    /// Renders the scene once, synchronously, while the first layout pass is still
    /// in flight — so the image is ready before this commit reaches the screen and
    /// there is never a frame with an empty scene in it. The cost lands on the
    /// launch screen (which is already up) instead of on a visible flash, and it
    /// warms the technique's Metal pipelines at the same time.
    private func captureFirstFrameIfNeeded() {
        guard !hasCapturedFirstFrame,
              sceneView.bounds.width > 0, sceneView.bounds.height > 0,
              sceneView.scene != nil else { return }
        hasCapturedFirstFrame = true
        // The floor and walls are built from the scene view's own layout callback,
        // which UIKit would otherwise run after this method returns — forcing it
        // first means the frame we capture has the table in it.
        sceneView.layoutIfNeeded()
        firstFrameView.image = sceneView.snapshot()
        // Once the real view is presenting there's no reason to keep a
        // full-screen image alive. Well past the point where the scene has drawn,
        // so dropping it can't reintroduce the gap.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.firstFrameView.image = nil
        }
    }
}

struct DiceSceneView: UIViewRepresentable {
    let controller: DiceController
    var shaderStyle: ShaderStyle

    /// Remembers which style is currently installed on the view, since
    /// SCNTechnique itself isn't comparable — without it every SwiftUI update
    /// would rebuild the technique (and its render targets) from scratch.
    final class Coordinator {
        var appliedStyle: ShaderStyle?
        var foregroundObserver: NSObjectProtocol?

        deinit {
            if let foregroundObserver {
                NotificationCenter.default.removeObserver(foregroundObserver)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ScreenLockedContainer {
        let container = ScreenLockedContainer(frame: .zero)
        let view = container.sceneView
        view.scene = controller.scene
        view.delegate = controller
        view.antialiasingMode = .none
        view.backgroundColor = .black
        view.technique = shaderStyle.makeTechnique()
        // The controller owns whether the view is playing: the scene is static
        // outside a roll, so rendering is driven by what actually changes rather
        // than left running.
        controller.attach(to: view)
        controller.applyBackground(shaderStyle.background)
        context.coordinator.appliedStyle = shaderStyle
        view.onLayout = { [weak controller] size in
            controller?.viewSizeChanged(size)
        }
        // Coming back from the background can leave the paused view without a
        // presented frame; a redraw request costs one frame and removes the
        // whole class of problem.
        context.coordinator.foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak controller] _ in
            controller?.requestRedraw()
        }
        return container
    }

    func updateUIView(_ uiView: ScreenLockedContainer, context: Context) {
        guard context.coordinator.appliedStyle != shaderStyle else { return }
        uiView.sceneView.technique = shaderStyle.makeTechnique()
        controller.applyBackground(shaderStyle.background)
        context.coordinator.appliedStyle = shaderStyle
        // `applyBackground` only redraws when the table itself changed; the
        // technique swap needs a frame either way.
        controller.requestRedraw()
    }
}
