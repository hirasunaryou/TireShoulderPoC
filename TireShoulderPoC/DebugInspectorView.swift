import SwiftUI
import SceneKit

struct DebugInspectorView: View {
    let title: String
    let input: ModelInput
    let scene: SCNScene?
    @Binding var config: AnalysisConfig
    let onReextract: () -> Void

    var body: some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 12) {
                if let scene {
                    SceneKitOverlayView(scene: scene)
                        .frame(height: 280)
                }

                thresholdSliders

                VStack(alignment: .leading, spacing: 4) {
                    Text("samples=\(input.package.totalSamples), rawBlue=\(input.package.rawBlueCount), rawRed=\(input.package.rawRedCount)")
                        .font(.footnote)
                    Text("geometryNodes=\(input.package.geometryNodeCount), skippedNoUVTriangles=\(input.package.skippedNoUVTriangles)")
                        .font(.footnote)
                }
                .foregroundStyle(.secondary)

                if !input.package.warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(input.package.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Button("キャッシュからマスク再抽出", action: onReextract)
                    .buttonStyle(.borderedProminent)

                materialList
            }
        }
    }

    private var thresholdSliders: some View {
        VStack(alignment: .leading, spacing: 8) {
            sliderRow(title: "Blue Hue Min", value: $config.blueHueMin, range: 0...360)
            sliderRow(title: "Blue Hue Max", value: $config.blueHueMax, range: 0...360)
            sliderRow(title: "Red Low Hue Max", value: $config.redLowHueMax, range: 0...180)
            sliderRow(title: "Red High Hue Min", value: $config.redHighHueMin, range: 180...360)
            sliderRow(title: "Min Saturation", value: $config.minSaturation, range: 0...1)
            sliderRow(title: "Min Value", value: $config.minValue, range: 0...1)
        }
    }

    private func sliderRow(title: String, value: Binding<Float>, range: ClosedRange<Float>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(title): \(value.wrappedValue, specifier: "%.3f")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(value: value, in: range)
        }
    }

    private var materialList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Material / Geometry Inspection")
                .font(.headline)

            ForEach(input.package.materialRecords) { record in
                VStack(alignment: .leading, spacing: 3) {
                    Text("node=\(record.nodeName), geometry=\(record.geometryName), materialIndex=\(record.materialIndex)")
                        .font(.footnote)
                    Text("hasUV=\(record.hasUV ? "yes" : "no"), hasVertexColor=\(record.hasVertexColor ? "yes" : "no")")
                        .font(.caption)
                    Text("triangles=\(record.triangleCount), sampled=\(record.sampledTriangleCount), source=\(record.textureSourceSummary)")
                        .font(.caption)
                }
                .padding(8)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}
