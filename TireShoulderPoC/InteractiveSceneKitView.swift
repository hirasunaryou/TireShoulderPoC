import SwiftUI
import SceneKit

struct InteractiveSceneKitView: UIViewRepresentable {
    let scene: SCNScene
    let pointOfView: SCNNode?
    let isBrushEditing: Bool
    let isPaintGestureEnabled: Bool
    let minStampDistance: Float
    let onSurfaceHit: ((Point3) -> Void)?
    let onCameraTransformChanged: ((simd_float4x4) -> Void)?
    let onResetView: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.scene = scene
        view.pointOfView = pointOfView
        view.backgroundColor = .clear
        view.autoenablesDefaultLighting = true
        configureCameraControls(for: view)

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = false
        view.addGestureRecognizer(pan)

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
        configureCameraControls(for: uiView)
        context.coordinator.parent = self
    }

    private func configureCameraControls(for view: SCNView) {
        // Paint時は誤操作を減らすため、回転は抑止しつつpinchのみ許可。
        view.allowsCameraControl = !isPaintGestureEnabled
        if isPaintGestureEnabled {
            view.defaultCameraController.interactionMode = .truck
        } else {
            view.defaultCameraController.interactionMode = .orbitTurntable
        }
    }

    final class Coordinator: NSObject {
        var parent: InteractiveSceneKitView
        private weak var view: SCNView?
        private var lastPanStampCenter: SIMD3<Float>?
        private var pinchBeganTransform: simd_float4x4?

        init(parent: InteractiveSceneKitView) {
            self.parent = parent
        }

        func attach(view: SCNView) {
            self.view = view
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            addStampIfNeeded(at: recognizer.location(in: recognizer.view), force: true)
            publishCameraTransform()
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard parent.isPaintGestureEnabled else {
                if recognizer.state == .ended || recognizer.state == .cancelled {
                    publishCameraTransform()
                }
                return
            }

            switch recognizer.state {
            case .began, .changed:
                addStampIfNeeded(at: recognizer.location(in: recognizer.view), force: false)
            default:
                lastPanStampCenter = nil
                publishCameraTransform()
            }
        }

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            guard parent.isBrushEditing,
                  parent.isPaintGestureEnabled,
                  let cameraNode = view?.pointOfView else { return }

            switch recognizer.state {
            case .began:
                pinchBeganTransform = cameraNode.simdTransform
            case .changed:
                guard let base = pinchBeganTransform else { return }
                cameraNode.simdTransform = scaledCameraTransform(base, scale: Float(recognizer.scale))
            default:
                pinchBeganTransform = nil
                publishCameraTransform()
            }
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            parent.onResetView?()
        }

        private func addStampIfNeeded(at point: CGPoint, force: Bool) {
            guard parent.isBrushEditing,
                  parent.isPaintGestureEnabled,
                  let view,
                  let onSurfaceHit = parent.onSurfaceHit,
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
            onSurfaceHit(Point3(hitPosition))
        }

        private func scaledCameraTransform(_ original: simd_float4x4, scale: Float) -> simd_float4x4 {
            guard let view else { return original }
            let clampedScale = min(max(scale, 0.6), 1.8)
            let current = view.pointOfView?.simdTransform ?? original
            let position = SIMD3<Float>(current.columns.3.x, current.columns.3.y, current.columns.3.z)
            let forward = -SIMD3<Float>(current.columns.2.x, current.columns.2.y, current.columns.2.z)
            let delta = (1 - clampedScale) * 0.025
            var result = current
            result.columns.3.x = position.x + forward.x * delta
            result.columns.3.y = position.y + forward.y * delta
            result.columns.3.z = position.z + forward.z * delta
            return result
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

        private func publishCameraTransform() {
            guard let transform = view?.pointOfView?.simdTransform else { return }
            parent.onCameraTransformChanged?(transform)
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
