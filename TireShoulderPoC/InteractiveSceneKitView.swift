import SwiftUI
import SceneKit

struct InteractiveSceneKitView: UIViewRepresentable {
    let scene: SCNScene
    let pointOfView: SCNNode?
    let isBrushEditing: Bool
    let minStampDistance: Float
    let cameraTransform: simd_float4x4?
    let onCameraTransformChange: ((simd_float4x4) -> Void)?
    let onDoubleTap: (() -> Void)?
    let onSurfaceHit: (Point3) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.scene = scene
        view.pointOfView = pointOfView
        view.backgroundColor = .clear
        view.autoenablesDefaultLighting = true
        // Brush中も2本指/Pinchでカメラ操作できるように常時有効化する。
        view.allowsCameraControl = true
        view.delegate = context.coordinator

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.numberOfTouchesRequired = 1
        tap.numberOfTapsRequired = 1
        tap.cancelsTouchesInView = false
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTouchesRequired = 1
        doubleTap.numberOfTapsRequired = 2
        doubleTap.cancelsTouchesInView = false
        tap.require(toFail: doubleTap)
        view.addGestureRecognizer(doubleTap)
        view.addGestureRecognizer(tap)

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        // 1本指ドラッグだけをstampに割り当てる。2本指はSceneKit標準カメラ操作に委譲。
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = false
        view.addGestureRecognizer(pan)

        context.coordinator.attach(view: view)
        context.coordinator.applyCameraTransformIfNeeded()
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        uiView.scene = scene
        uiView.pointOfView = pointOfView
        uiView.allowsCameraControl = true
        context.coordinator.parent = self
        context.coordinator.applyCameraTransformIfNeeded()
    }

    final class Coordinator: NSObject, SCNSceneRendererDelegate {
        var parent: InteractiveSceneKitView
        private weak var view: SCNView?
        private var lastPanStampCenter: SIMD3<Float>?
        private var lastPublishedCameraTransform: simd_float4x4?

        init(parent: InteractiveSceneKitView) {
            self.parent = parent
        }

        func attach(view: SCNView) {
            self.view = view
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            addStampIfNeeded(at: recognizer.location(in: recognizer.view), force: true)
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            parent.onDoubleTap?()
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began, .changed:
                addStampIfNeeded(at: recognizer.location(in: recognizer.view), force: false)
            default:
                lastPanStampCenter = nil
            }
        }

        private func addStampIfNeeded(at point: CGPoint, force: Bool) {
            guard parent.isBrushEditing,
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

        func applyCameraTransformIfNeeded() {
            guard let desired = parent.cameraTransform, let pointOfViewNode = view?.pointOfView else { return }
            pointOfViewNode.simdTransform = desired
            lastPublishedCameraTransform = desired
        }

        func renderer(_ renderer: any SCNSceneRenderer, updateAtTime time: TimeInterval) {
            guard let transform = view?.pointOfView?.simdTransform else { return }
            if let lastPublishedCameraTransform, transformsAreClose(lastPublishedCameraTransform, transform) {
                return
            }
            lastPublishedCameraTransform = transform
            DispatchQueue.main.async { [weak self] in
                self?.parent.onCameraTransformChange?(transform)
            }
        }

        private func transformsAreClose(_ lhs: simd_float4x4, _ rhs: simd_float4x4, epsilon: Float = 0.000_01) -> Bool {
            let left = lhs.columns
            let right = rhs.columns
            for index in 0..<4 {
                if simd_length(left[index] - right[index]) > epsilon {
                    return false
                }
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
