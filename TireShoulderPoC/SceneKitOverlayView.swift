import SwiftUI
import SceneKit

struct SceneKitOverlayView: View {
    let scene: SCNScene

    var body: some View {
        SceneView(
            scene: scene,
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
