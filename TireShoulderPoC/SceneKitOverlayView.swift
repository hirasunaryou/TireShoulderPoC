import SwiftUI
import SceneKit

struct SceneKitOverlayView: View {
    let scene: SCNScene
    var pointOfView: SCNNode? = nil
    var isBrushEditing = false
    var minStampDistance: Float = 0.002
    var cameraTransform: simd_float4x4? = nil
    var onCameraTransformChange: ((simd_float4x4) -> Void)? = nil
    var onDoubleTap: (() -> Void)? = nil
    var onSurfaceHit: ((Point3) -> Void)? = nil

    var body: some View {
        Group {
            if let onSurfaceHit {
                InteractiveSceneKitView(
                    scene: scene,
                    pointOfView: pointOfView,
                    isBrushEditing: isBrushEditing,
                    minStampDistance: minStampDistance,
                    cameraTransform: cameraTransform,
                    onCameraTransformChange: onCameraTransformChange,
                    onDoubleTap: onDoubleTap,
                    onSurfaceHit: onSurfaceHit
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
