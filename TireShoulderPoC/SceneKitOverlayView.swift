import SwiftUI
import SceneKit

struct SceneKitOverlayView: View {
    let scene: SCNScene
    var pointOfView: SCNNode? = nil
    var isBrushEditing = false
    var isPaintGestureEnabled = false
    var minStampDistance: Float = 0.002
    var onSurfaceHit: ((Point3) -> Void)? = nil
    var onCameraTransformChanged: ((simd_float4x4) -> Void)? = nil
    var onFitTapped: ((InspectorCameraFitTarget) -> Void)? = nil

    var body: some View {
        ZStack(alignment: .topLeading) {
            InteractiveSceneKitView(
                scene: scene,
                pointOfView: pointOfView,
                isBrushEditing: isBrushEditing,
                isPaintGestureEnabled: isPaintGestureEnabled,
                minStampDistance: minStampDistance,
                onSurfaceHit: onSurfaceHit,
                onCameraTransformChanged: onCameraTransformChanged,
                onResetView: {
                    onFitTapped?(.reset)
                }
            )

            if isBrushEditing {
                brushHUD
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

    private var brushHUD: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text("1本指: 塗る")
                Text("Navigate: 視点移動")
                Text("Pinch: 拡大縮小")
                Text("Double Tap: Reset")
            }
            .font(.caption2)
            .padding(6)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 6) {
                fitButton(title: "Model", target: .model)
                fitButton(title: "ROI", target: .roi)
                fitButton(title: "Brush", target: .brush)
                fitButton(title: "Reset", target: .reset)
            }
        }
    }

    private func fitButton(title: String, target: InspectorCameraFitTarget) -> some View {
        Button(title) {
            onFitTapped?(target)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.mini)
    }
}
