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
        uiView.allowsCameraControl = shouldAllowSceneKitCameraControl
        context.coordinator.syncManagedCamera(with: uiView, preferredPointOfView: pointOfView)
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
        private var managedCameraNode: SCNNode?
        private var lastPanStampCenter: SIMD3<Float>?
        private var lastTwoFingerPan: CGPoint?
        private var lastSentCameraTransform: simd_float4x4?
        private var orbitTarget: SIMD3<Float>?

        init(parent: InteractiveSceneKitView) {
            self.parent = parent
        }

        func attach(view: SCNView) {
            self.view = view
            view.delegate = self
            syncManagedCamera(with: view, preferredPointOfView: parent.pointOfView)
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
                  let cameraNode = managedCameraNode ?? view.pointOfView else { return }

            let location = recognizer.location(in: view)
            switch recognizer.state {
            case .began:
                lastTwoFingerPan = location
                orbitTarget = resolveOrbitTarget(in: view)
            case .changed:
                guard let lastTwoFingerPan else { return }
                let delta = CGPoint(x: location.x - lastTwoFingerPan.x, y: location.y - lastTwoFingerPan.y)
                orbitCamera(cameraNode, around: orbitTarget ?? resolveOrbitTarget(in: view), delta: delta)
                self.lastTwoFingerPan = location
                publishCameraTransformIfNeeded(cameraNode: cameraNode)
            default:
                lastTwoFingerPan = nil
                orbitTarget = nil
            }
        }

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            guard parent.isBrushEditing,
                  let view,
                  let cameraNode = managedCameraNode ?? view.pointOfView else { return }
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
            syncManagedCamera(with: view, preferredPointOfView: parent.pointOfView)
            guard let cameraNode = managedCameraNode ?? view.pointOfView else { return }
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
                orbitTarget = SIMD3<Float>(hit.worldCoordinates)
                return SIMD3<Float>(hit.worldCoordinates)
            }
            return nil
        }

        func renderer(_ renderer: any SCNSceneRenderer, updateAtTime time: TimeInterval) {
            guard let view,
                  let cameraNode = managedCameraNode ?? view.pointOfView else { return }
            let transform = cameraNode.simdTransform
            if !approximatelyEqual(lastSentCameraTransform ?? matrix_identity_float4x4, transform) {
                lastSentCameraTransform = transform
                DispatchQueue.main.async { [parent] in
                    parent.onCameraTransformChanged(transform)
                }
            }
        }

        func syncManagedCamera(with view: SCNView, preferredPointOfView: SCNNode?) {
            if managedCameraNode == nil {
                let sourceNode = preferredPointOfView ?? view.pointOfView
                let node = SCNNode()
                node.camera = sourceNode?.camera ?? SCNCamera()
                node.simdTransform = sourceNode?.simdTransform ?? matrix_identity_float4x4
                managedCameraNode = node
            } else if let preferredPointOfView,
                      let camera = managedCameraNode?.camera,
                      let preferredCamera = preferredPointOfView.camera {
                // 新sceneに切り替わってもFOV等の設定だけは同期し、transformは維持する。
                camera.fieldOfView = preferredCamera.fieldOfView
                camera.zNear = preferredCamera.zNear
                camera.zFar = preferredCamera.zFar
            }
            view.pointOfView = managedCameraNode
        }

        private func resolveOrbitTarget(in view: SCNView) -> SIMD3<Float> {
            if let orbitTarget { return orbitTarget }
            if let meshNode = view.scene?.rootNode.childNode(withName: "InspectableMeshRoot", recursively: true) {
                let (minV, maxV) = meshNode.boundingBox
                let localCenter = SCNVector3(
                    (minV.x + maxV.x) * 0.5,
                    (minV.y + maxV.y) * 0.5,
                    (minV.z + maxV.z) * 0.5
                )
                let worldCenter = meshNode.convertPosition(localCenter, to: nil)
                return SIMD3<Float>(worldCenter)
            }
            return SIMD3<Float>(0, 0, 0)
        }

        private func orbitCamera(_ cameraNode: SCNNode, around target: SIMD3<Float>, delta: CGPoint) {
            let currentPosition = cameraNode.simdPosition
            var offset = currentPosition - target
            let yaw = Float(-delta.x) * 0.008
            let pitch = Float(-delta.y) * 0.006

            let yawQuat = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
            offset = yawQuat.act(offset)

            let forward = simd_normalize(target - currentPosition)
            let right = simd_normalize(simd_cross(forward, SIMD3<Float>(0, 1, 0)))
            let pitchQuat = simd_quatf(angle: pitch, axis: right)
            let pitchedOffset = pitchQuat.act(offset)
            // 真上/真下での操作破綻を避けるため、up成分に緩い制限をかける。
            let maxVerticalRatio: Float = 0.94
            let length = max(simd_length(pitchedOffset), 0.0001)
            let verticalRatio = pitchedOffset.y / length
            if abs(verticalRatio) < maxVerticalRatio {
                offset = pitchedOffset
            }

            cameraNode.simdPosition = target + offset
            cameraNode.simdLook(at: target)
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
