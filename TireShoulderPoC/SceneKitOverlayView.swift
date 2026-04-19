import SwiftUI
import SceneKit

struct SceneKitOverlayView: View {
    let scene: SCNScene
    var pointOfView: SCNNode? = nil
    var isBrushEditing = false
    var minStampDistance: Float = 0.002
    var onSurfaceHit: ((Point3) -> Void)? = nil
    var onCameraTransformChanged: ((simd_float4x4) -> Void)? = nil
    var resetViewToken: Int = 0
    var showBrushGuide = false

    var body: some View {
        InteractiveSceneKitView(
            scene: scene,
            pointOfView: pointOfView,
            isBrushEditing: isBrushEditing,
            minStampDistance: minStampDistance,
            onSurfaceHit: onSurfaceHit,
            onCameraTransformChanged: onCameraTransformChanged,
            resetViewToken: resetViewToken
        )
        .overlay(alignment: .bottomLeading) {
            if showBrushGuide {
                HStack(spacing: 6) {
                    Image(systemName: "smallcircle.filled.circle")
                    Text("Brush cursor")
                }
                .font(.caption2)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(8)
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
