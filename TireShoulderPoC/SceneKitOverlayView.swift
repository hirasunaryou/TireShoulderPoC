import SwiftUI
import SceneKit

struct SceneKitOverlayView: View {
    let scene: SCNScene
    var pointOfView: SCNNode? = nil
    var isBrushEditing = false
    var brushInteractionMode: InteractiveSceneKitView.BrushInteractionMode = .paint
    var minStampDistance: Float = 0.002
    var cameraTransform: simd_float4x4? = nil
    var onSurfaceHit: ((Point3) -> Void)? = nil
    var onCameraTransformChanged: ((simd_float4x4) -> Void)? = nil
    var onDoubleTapReset: (() -> Void)? = nil

    var body: some View {
        Group {
            if let onSurfaceHit {
                InteractiveSceneKitView(
                    scene: scene,
                    pointOfView: pointOfView,
                    isBrushEditing: isBrushEditing,
                    brushInteractionMode: brushInteractionMode,
                    minStampDistance: minStampDistance,
                    cameraTransform: cameraTransform,
                    onSurfaceHit: onSurfaceHit,
                    onCameraTransformChanged: onCameraTransformChanged ?? { _ in },
                    onDoubleTapReset: onDoubleTapReset ?? {}
                )
            } else {
                SceneView(
                    scene: scene,
                    pointOfView: pointOfView,
                    options: [.autoenablesDefaultLighting, .allowsCameraControl]
                )
            }
        }
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
    }
}
