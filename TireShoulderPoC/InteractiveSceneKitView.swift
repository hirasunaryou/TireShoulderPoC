import SwiftUI
import SceneKit

struct InteractiveSceneKitView: UIViewRepresentable {
    let scene: SCNScene
    let pointOfView: SCNNode?
    let isBrushEditing: Bool
    let minStampDistance: Float
    let onSurfaceHit: ((Point3) -> Void)?
    let onCameraTransformChanged: ((simd_float4x4) -> Void)?
    let resetViewToken: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.scene = scene
        view.pointOfView = pointOfView
        view.backgroundColor = .clear
        view.autoenablesDefaultLighting = true
        view.allowsCameraControl = true

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false
        context.coordinator.paintTapRecognizer = tap
        view.addGestureRecognizer(tap)

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTapReset(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.cancelsTouchesInView = false
        tap.require(toFail: doubleTap)
        context.coordinator.doubleTapResetRecognizer = doubleTap
        view.addGestureRecognizer(doubleTap)

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = false
        context.coordinator.paintPanRecognizer = pan
        view.addGestureRecognizer(pan)

        context.coordinator.attach(view: view)
        context.coordinator.configureBuiltInCameraGesturesIfNeeded()
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        uiView.scene = scene
        uiView.pointOfView = pointOfView ?? uiView.pointOfView ?? scene.rootNode.childNode(withName: "InspectorCamera", recursively: true)
        uiView.allowsCameraControl = true
        context.coordinator.parent = self
        context.coordinator.configureBuiltInCameraGesturesIfNeeded()
        context.coordinator.applyExternalCameraTransformIfNeeded()
        context.coordinator.handleResetIfNeeded()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: InteractiveSceneKitView
        private weak var view: SCNView?
        private var lastPanStampCenter: SIMD3<Float>?
        private var observedRecognizerIDs = Set<ObjectIdentifier>()
        private var lastAppliedTransform: simd_float4x4?
        private var lastResetViewToken: Int = -1
        weak var paintTapRecognizer: UITapGestureRecognizer?
        weak var paintPanRecognizer: UIPanGestureRecognizer?
        weak var doubleTapResetRecognizer: UITapGestureRecognizer?

        init(parent: InteractiveSceneKitView) {
            self.parent = parent
        }

        func attach(view: SCNView) {
            self.view = view
            paintTapRecognizer?.delegate = self
            paintPanRecognizer?.delegate = self
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

        @objc func handleDoubleTapReset(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let view else { return }
            if let defaultCamera = view.scene?.rootNode.childNode(withName: "InspectorCamera", recursively: true) {
                view.pointOfView?.simdTransform = defaultCamera.simdTransform
                emitCurrentCameraTransform()
            }
        }

        @objc private func handleCameraGestureChanged(_ recognizer: UIGestureRecognizer) {
            guard recognizer.state == .changed || recognizer.state == .ended else { return }
            emitCurrentCameraTransform()
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        func configureBuiltInCameraGesturesIfNeeded() {
            guard let view else { return }
            for recognizer in view.gestureRecognizers ?? [] {
                if recognizer === paintPanRecognizer || recognizer === paintTapRecognizer {
                    continue
                }

                if let pan = recognizer as? UIPanGestureRecognizer {
                    if parent.isBrushEditing {
                        // 1本指は塗り操作に優先して割り当て、カメラ移動は2本指に寄せる。
                        pan.minimumNumberOfTouches = max(pan.minimumNumberOfTouches, 2)
                    } else {
                        pan.minimumNumberOfTouches = 1
                    }
                }

                let id = ObjectIdentifier(recognizer)
                if !observedRecognizerIDs.contains(id) {
                    recognizer.addTarget(self, action: #selector(handleCameraGestureChanged(_:)))
                    observedRecognizerIDs.insert(id)
                }
            }
        }

        func applyExternalCameraTransformIfNeeded() {
            guard let transform = parent.pointOfView?.simdTransform ?? lastAppliedTransform,
                  let view else { return }
            if let parentTransform = parent.pointOfView?.simdTransform {
                lastAppliedTransform = parentTransform
            }
            guard let pov = view.pointOfView else { return }
            if let latest = parent.pointOfView?.simdTransform {
                pov.simdTransform = latest
                return
            }
            pov.simdTransform = transform
        }

        func handleResetIfNeeded() {
            guard parent.resetViewToken != lastResetViewToken, let view else { return }
            lastResetViewToken = parent.resetViewToken
            if let defaultCamera = view.scene?.rootNode.childNode(withName: "InspectorCamera", recursively: true) {
                view.pointOfView?.simdTransform = defaultCamera.simdTransform
                emitCurrentCameraTransform()
            }
        }

        private func emitCurrentCameraTransform() {
            guard let transform = view?.pointOfView?.simdTransform else { return }
            lastAppliedTransform = transform
            parent.onCameraTransformChanged?(transform)
        }

        private func addStampIfNeeded(at point: CGPoint, force: Bool) {
            guard parent.isBrushEditing,
                  let view,
                  let hitPosition = meshWorldPosition(from: view, at: point),
                  let onSurfaceHit = parent.onSurfaceHit else {
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
