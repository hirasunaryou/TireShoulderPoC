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
        context.coordinator.refreshOrbitPivot(using: uiView.scene)
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
        private var orbitPivot: SIMD3<Float>?

        init(parent: InteractiveSceneKitView) {
            self.parent = parent
        }

        func attach(view: SCNView) {
            self.view = view
            view.delegate = self
            orbitPivot = inspectableMeshCenter(from: view.scene)
        }

        func refreshOrbitPivot(using scene: SCNScene?) {
            orbitPivot = inspectableMeshCenter(from: scene) ?? orbitPivot
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
                // Paintモードでも2本指でカメラをオービットさせる。
                // これにより「一方向からしか塗れない」問題を減らす。
                orbitCamera(cameraNode: cameraNode, screenDelta: delta)
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
            // scene再構築で新しいcamera nodeに差し替わるため、直近送信値ではなく
            // 「現在nodeのtransform」と比較して必要なら必ず復元する。
            if approximatelyEqual(cameraNode.simdTransform, transform) {
                return
            }
            cameraNode.simdTransform = transform
            lastSentCameraTransform = transform
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

        private func orbitCamera(cameraNode: SCNNode, screenDelta: CGPoint) {
            let pivot = orbitPivot ?? cameraOrbitFallbackPivot(cameraNode: cameraNode)
            let yaw = Float(screenDelta.x) * 0.008
            let pitch = Float(screenDelta.y) * 0.006

            var offset = cameraNode.simdPosition - pivot
            let worldUp = SIMD3<Float>(0, 1, 0)
            let yawQuat = simd_quatf(angle: yaw, axis: worldUp)
            offset = yawQuat.act(offset)

            let right = simd_normalize(simd_cross(worldUp, offset))
            if right.x.isFinite && right.y.isFinite && right.z.isFinite {
                let pitchQuat = simd_quatf(angle: pitch, axis: right)
                offset = pitchQuat.act(offset)
            }

            cameraNode.simdPosition = pivot + offset
            cameraNode.simdLook(at: pivot)
        }

        private func inspectableMeshCenter(from scene: SCNScene?) -> SIMD3<Float>? {
            guard let meshRoot = scene?.rootNode.childNode(withName: "InspectableMeshRoot", recursively: true) else {
                return nil
            }
            let (minV, maxV) = meshRoot.boundingBox
            guard minV.x.isFinite, minV.y.isFinite, minV.z.isFinite,
                  maxV.x.isFinite, maxV.y.isFinite, maxV.z.isFinite else { return nil }
            let centerLocal = SCNVector3(
                (minV.x + maxV.x) * 0.5,
                (minV.y + maxV.y) * 0.5,
                (minV.z + maxV.z) * 0.5
            )
            let centerWorld = meshRoot.convertPosition(centerLocal, to: nil)
            return SIMD3<Float>(centerWorld.x, centerWorld.y, centerWorld.z)
        }

        private func cameraOrbitFallbackPivot(cameraNode: SCNNode) -> SIMD3<Float> {
            let forward = cameraNode.simdWorldFront
            let fallbackDistance: Float = 0.05
            return cameraNode.simdPosition + (forward * fallbackDistance)
        }

        func renderer(_ renderer: any SCNSceneRenderer, updateAtTime time: TimeInterval) {
            guard let view,
                  let cameraNode = view.pointOfView else { return }
            orbitPivot = orbitPivot ?? inspectableMeshCenter(from: view.scene)
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
