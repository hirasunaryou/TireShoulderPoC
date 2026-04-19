import SwiftUI
import SceneKit

struct InteractiveSceneKitView: UIViewRepresentable {
    enum BrushInteractionMode: Hashable {
        case paint
        case navigate
    }

    let scene: SCNScene
    let pointOfView: SCNNode?
    let isBrushEditing: Bool
    let brushInteractionMode: BrushInteractionMode
    let minStampDistance: Float
    let cameraTransform: simd_float4x4?
    let onSurfaceHit: (Point3) -> Void
    let onCameraTransformChanged: (simd_float4x4) -> Void
    let onDoubleTapReset: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.scene = scene
        view.pointOfView = pointOfView
        view.backgroundColor = .clear
        view.autoenablesDefaultLighting = true
        view.allowsCameraControl = shouldAllowSceneKitCameraControl

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = false
        view.addGestureRecognizer(pan)

        let twoFingerPan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTwoFingerPan(_:)))
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.maximumNumberOfTouches = 2
        twoFingerPan.cancelsTouchesInView = false
        view.addGestureRecognizer(twoFingerPan)

        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        pinch.cancelsTouchesInView = false
        view.addGestureRecognizer(pinch)

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.cancelsTouchesInView = false
        view.addGestureRecognizer(doubleTap)
        tap.require(toFail: doubleTap)

        context.coordinator.attach(view: view)
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        uiView.scene = scene
        uiView.pointOfView = pointOfView
        uiView.allowsCameraControl = shouldAllowSceneKitCameraControl
        if let cameraTransform {
            context.coordinator.applyCameraTransformIfNeeded(cameraTransform, to: uiView)
        }
        context.coordinator.parent = self
    }

    private var shouldAllowSceneKitCameraControl: Bool {
        if !isBrushEditing { return true }
        return brushInteractionMode == .navigate
    }

    final class Coordinator: NSObject, SCNSceneRendererDelegate {
        var parent: InteractiveSceneKitView
        private weak var view: SCNView?
        private var lastPanStampCenter: SIMD3<Float>?
        private var lastTwoFingerPan: CGPoint?
        private var lastSentCameraTransform: simd_float4x4?

        init(parent: InteractiveSceneKitView) {
            self.parent = parent
        }

        func attach(view: SCNView) {
            self.view = view
            view.delegate = self
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            addStampIfNeeded(at: recognizer.location(in: recognizer.view), force: true)
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began, .changed:
                addStampIfNeeded(at: recognizer.location(in: recognizer.view), force: false)
            default:
                lastPanStampCenter = nil
            }
        }

        @objc func handleTwoFingerPan(_ recognizer: UIPanGestureRecognizer) {
            guard parent.isBrushEditing,
                  parent.brushInteractionMode == .paint,
                  let view,
                  let cameraNode = view.pointOfView else { return }

            let location = recognizer.location(in: view)
            switch recognizer.state {
            case .began:
                lastTwoFingerPan = location
            case .changed:
                guard let lastTwoFingerPan else { return }
                let delta = CGPoint(x: location.x - lastTwoFingerPan.x, y: location.y - lastTwoFingerPan.y)
                // Paintモード中の2本指パンは「簡易カメラ平行移動」に割り当てる。
                // オービットほど厳密ではないが、iPhone片手操作で対象をすぐ戻せることを優先。
                let distance = max(simd_length(cameraNode.simdPosition), 0.05)
                let scale = Float(0.0016) * distance
                let localMove = SIMD3<Float>(-Float(delta.x) * scale, Float(delta.y) * scale, 0)
                cameraNode.simdLocalTranslate(by: localMove)
                self.lastTwoFingerPan = location
                publishCameraTransformIfNeeded(cameraNode: cameraNode)
            default:
                lastTwoFingerPan = nil
            }
        }

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            guard parent.isBrushEditing,
                  let view,
                  let cameraNode = view.pointOfView else { return }
            // pinchはPaint/Navigateの両モードで有効にし、ブラシ編集中でも必ずズームできるようにする。
            let scaleDelta = Float(recognizer.scale - 1)
            if abs(scaleDelta) > 0.0001 {
                let distance = max(simd_length(cameraNode.simdPosition), 0.05)
                let zMove = distance * scaleDelta * 0.45
                cameraNode.simdLocalTranslate(by: SIMD3<Float>(0, 0, zMove))
                recognizer.scale = 1
                publishCameraTransformIfNeeded(cameraNode: cameraNode)
            }
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            parent.onDoubleTapReset()
        }

        private func addStampIfNeeded(at point: CGPoint, force: Bool) {
            guard parent.isBrushEditing,
                  parent.brushInteractionMode == .paint,
                  let view,
                  let hitPosition = meshWorldPosition(from: view, at: point) else {
                return
            }

            if !force, let lastPanStampCenter {
                let distance = simd_length(hitPosition - lastPanStampCenter)
                if distance < max(parent.minStampDistance, 0.0008) {
                    return
                }
            }

            lastPanStampCenter = hitPosition
            parent.onSurfaceHit(Point3(hitPosition))
        }

        func applyCameraTransformIfNeeded(_ transform: simd_float4x4, to view: SCNView) {
            guard let cameraNode = view.pointOfView else { return }
            if let lastSentCameraTransform, approximatelyEqual(lastSentCameraTransform, transform) {
                return
            }
            cameraNode.simdTransform = transform
        }

        private func publishCameraTransformIfNeeded(cameraNode: SCNNode) {
            let transform = cameraNode.simdTransform
            lastSentCameraTransform = transform
            parent.onCameraTransformChanged(transform)
        }

        private func approximatelyEqual(_ lhs: simd_float4x4, _ rhs: simd_float4x4, epsilon: Float = 0.000_001) -> Bool {
            let l = [
                lhs.columns.0.x, lhs.columns.0.y, lhs.columns.0.z, lhs.columns.0.w,
                lhs.columns.1.x, lhs.columns.1.y, lhs.columns.1.z, lhs.columns.1.w,
                lhs.columns.2.x, lhs.columns.2.y, lhs.columns.2.z, lhs.columns.2.w,
                lhs.columns.3.x, lhs.columns.3.y, lhs.columns.3.z, lhs.columns.3.w
            ]
            let r = [
                rhs.columns.0.x, rhs.columns.0.y, rhs.columns.0.z, rhs.columns.0.w,
                rhs.columns.1.x, rhs.columns.1.y, rhs.columns.1.z, rhs.columns.1.w,
                rhs.columns.2.x, rhs.columns.2.y, rhs.columns.2.z, rhs.columns.2.w,
                rhs.columns.3.x, rhs.columns.3.y, rhs.columns.3.z, rhs.columns.3.w
            ]
            for i in 0..<16 where abs(l[i] - r[i]) > epsilon {
                return false
            }
            return true
        }

        private func meshWorldPosition(from view: SCNView, at point: CGPoint) -> SIMD3<Float>? {
            let hits = view.hitTest(point, options: [
                .firstFoundOnly: false,
                .boundingBoxOnly: false,
                .ignoreHiddenNodes: true
            ])

            for hit in hits {
                guard hit.node.name == "InspectableMeshRoot" || hit.node.parent?.name == "InspectableMeshRoot" || hit.node.ancestor(named: "InspectableMeshRoot") != nil else {
                    continue
                }
                return SIMD3<Float>(hit.worldCoordinates)
            }
            return nil
        }

        func renderer(_ renderer: any SCNSceneRenderer, updateAtTime time: TimeInterval) {
            guard let view,
                  let cameraNode = view.pointOfView else { return }
            let transform = cameraNode.simdTransform
            if !approximatelyEqual(lastSentCameraTransform ?? matrix_identity_float4x4, transform) {
                lastSentCameraTransform = transform
                DispatchQueue.main.async { [parent] in
                    parent.onCameraTransformChanged(transform)
                }
            }
        }
    }
}

private extension SCNNode {
    func ancestor(named targetName: String) -> SCNNode? {
        var cursor: SCNNode? = self
        while let node = cursor {
            if node.name == targetName {
                return node
            }
            cursor = node.parent
        }
        return nil
    }
}
