import SwiftUI
import SceneKit

struct SceneKitOverlayView: View {
    let scene: SCNScene
    var pointOfView: SCNNode? = nil

    var body: some View {
        SceneView(
            scene: scene,
            pointOfView: pointOfView,
            options: [.autoenablesDefaultLighting, .allowsCameraControl]
        )
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
    }
}
