import SwiftUI
import SceneKit

struct InteractiveSceneKitView: UIViewRepresentable {
    let scene: SCNScene
    let cameraNodeName: String
    let isBrushEditing: Bool
    let minStampDistanceMeters: Float
    let onSurfaceHit: (Point3) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.scene = scene
        view.backgroundColor = UIColor(white: 0.07, alpha: 1.0)
        view.autoenablesDefaultLighting = true
        view.allowsCameraControl = !isBrushEditing
        if let cameraNode = scene.rootNode.childNode(withName: cameraNodeName, recursively: true) {
            view.pointOfView = cameraNode
        }

        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        let panGesture = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        panGesture.maximumNumberOfTouches = 1
        view.addGestureRecognizer(tapGesture)
        view.addGestureRecognizer(panGesture)

        context.coordinator.scnView = view
        context.coordinator.tapGesture = tapGesture
        context.coordinator.panGesture = panGesture
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        context.coordinator.parent = self
        uiView.scene = scene
        if let cameraNode = scene.rootNode.childNode(withName: cameraNodeName, recursively: true) {
            uiView.pointOfView = cameraNode
        }
        uiView.allowsCameraControl = !isBrushEditing
        context.coordinator.tapGesture?.isEnabled = isBrushEditing
        context.coordinator.panGesture?.isEnabled = isBrushEditing
    }

    final class Coordinator: NSObject {
        var parent: InteractiveSceneKitView
        weak var scnView: SCNView?
        weak var tapGesture: UITapGestureRecognizer?
        weak var panGesture: UIPanGestureRecognizer?
        private var lastPanStampPoint: SIMD3<Float>?

        init(parent: InteractiveSceneKitView) {
            self.parent = parent
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended,
                  let view = scnView else { return }
            let point = gesture.location(in: view)
            if let worldPoint = resolveMeshHit(in: view, at: point) {
                parent.onSurfaceHit(Point3(worldPoint))
            }
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let view = scnView else { return }

            if gesture.state == .began {
                lastPanStampPoint = nil
            }

            guard gesture.state == .began || gesture.state == .changed else {
                if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
                    lastPanStampPoint = nil
                }
                return
            }

            let location = gesture.location(in: view)
            guard let hitPoint = resolveMeshHit(in: view, at: location) else { return }

            if let previous = lastPanStampPoint {
                let distance = simd_length(hitPoint - previous)
                guard distance >= parent.minStampDistanceMeters else { return }
            }

            lastPanStampPoint = hitPoint
            parent.onSurfaceHit(Point3(hitPoint))
        }

        private func resolveMeshHit(in view: SCNView, at screenPoint: CGPoint) -> SIMD3<Float>? {
            let options: [SCNHitTestOption: Any] = [
                .firstFoundOnly: false,
                .backFaceCulling: false,
                .ignoreHiddenNodes: true
            ]
            let results = view.hitTest(screenPoint, options: options)
            // オーバーレイ点群ではなく生メッシュに当たった結果だけを採用する。
            for result in results {
                if hasRawMeshAncestor(result.node) {
                    let world = result.worldCoordinates
                    return SIMD3<Float>(world.x, world.y, world.z)
                }
            }
            return nil
        }

        private func hasRawMeshAncestor(_ node: SCNNode) -> Bool {
            var cursor: SCNNode? = node
            while let current = cursor {
                if current.name == "RawMeshContainer" {
                    return true
                }
                cursor = current.parent
            }
            return false
        }
    }
}
