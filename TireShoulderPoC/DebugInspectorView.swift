import SwiftUI
import SceneKit

struct DebugInspectorView: View {
    @EnvironmentObject private var appModel: AppModel

    let kind: ModelKind
    let input: ModelInput

    @State private var inspectorScene: SCNScene?
    @State private var sceneError: String?
    @State private var showBluePoints = true
    @State private var showRedPoints = true

    var body: some View {
        GroupBox("\(kind.rawValue) Debug Inspector") {
            VStack(alignment: .leading, spacing: 10) {
                if let inspectorScene {
                    SceneKitOverlayView(scene: inspectorScene)
                        .frame(height: 280)
                } else if let sceneError {
                    Text(sceneError)
                        .foregroundStyle(.red)
                } else {
                    ProgressView()
                }

                Toggle("青ポイント表示", isOn: $showBluePoints)
                Toggle("赤ポイント表示", isOn: $showRedPoints)

                VStack(alignment: .leading, spacing: 4) {
                    Text("geometryNodes: \(input.package.geometryNodeCount)")
                    Text("totalSamples: \(input.package.totalSamples)")
                    Text("rawBlue/rawRed: \(input.package.rawBlueCount) / \(input.package.rawRedCount)")
                    Text("reducedBlue/reducedRed: \(input.package.bluePoints.count) / \(input.package.redPoints.count)")
                    Text("skippedNoUVTriangles: \(input.package.skippedNoUVTriangles)")
                    Text("cachedSamples: \(input.package.cachedSamples.count)")
                }
                .font(.footnote)

                cachedSampleDiagnosticsSection

                if !input.package.warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Warnings")
                            .font(.subheadline.bold())
                        ForEach(input.package.warnings, id: \.self) { warning in
                            Text("• \(warning)")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                thresholdEditor

                HStack {
                    Button("キャッシュから再抽出") {
                        appModel.reextractMasks(kind: kind)
                        refreshInspectorScene()
                    }
                    .buttonStyle(.borderedProminent)

                    Spacer()
                }

                materialRecordSection
                modelIOMaterialRecordSection
            }
        }
        .onAppear { refreshInspectorScene() }
        .onChange(of: showBluePoints) { _, _ in refreshInspectorScene() }
        .onChange(of: showRedPoints) { _, _ in refreshInspectorScene() }
    }

    private var thresholdEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mask Thresholds")
                .font(.subheadline.bold())

            sliderRow(label: "Blue Hue Min", value: blueHueMinBinding, range: 0 ... 360)
            sliderRow(label: "Blue Hue Max", value: blueHueMaxBinding, range: 0 ... 360)
            sliderRow(label: "Red Low Max", value: $appModel.config.redHueLowMax, range: 0 ... 120)
            sliderRow(label: "Red High Min", value: $appModel.config.redHueHighMin, range: 240 ... 360)
            sliderRow(label: "Min Saturation", value: $appModel.config.minSaturation, range: 0 ... 1)
            sliderRow(label: "Min Value", value: $appModel.config.minValue, range: 0 ... 1)
        }
    }

    private var materialRecordSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SceneKit Material Inspection")
                .font(.subheadline.bold())

            ForEach(input.package.materialRecords) { record in
                VStack(alignment: .leading, spacing: 2) {
                    Text("node=\(record.nodeName), geo=\(record.geometryName), matIdx=\(record.materialIndex)")
                    Text("UV=\(record.hasUV ? "Y" : "N"), VColor=\(record.hasVertexColor ? "Y" : "N"), triangles=\(record.triangleCount), sampled=\(record.sampledTriangleCount)")
                    Text("texture=\(record.textureSourceSummary), lighting=\(record.lightingModelName), transparency=\(record.transparency, specifier: "%.3f")")
                    Text("types D/E/Mul/SI/T/M/R = \(record.diffuseType) / \(record.emissionType) / \(record.multiplyType) / \(record.selfIlluminationType) / \(record.transparentType) / \(record.metalnessType) / \(record.roughnessType)")
                    Text("transformIdentity D/E/Mul/SI/T/M/R = \(boolText(record.diffuseTransformIsIdentity))/\(boolText(record.emissionTransformIsIdentity))/\(boolText(record.multiplyTransformIsIdentity))/\(boolText(record.selfIlluminationTransformIsIdentity))/\(boolText(record.transparentTransformIsIdentity))/\(boolText(record.metalnessTransformIsIdentity))/\(boolText(record.roughnessTransformIsIdentity))")
                }
                .font(.caption)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var modelIOMaterialRecordSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Model I/O Inspection")
                .font(.subheadline.bold())

            if input.package.modelIOMaterialRecords.isEmpty {
                Text("No Model I/O materials were discovered.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(input.package.modelIOMaterialRecords) { record in
                VStack(alignment: .leading, spacing: 2) {
                    Text("mesh=\(record.meshName), submesh=\(record.submeshIndex), material=\(record.materialName)")
                    Text("baseColor=\(record.baseColorSummary)")
                    ForEach(record.allSemanticSummaries, id: \.self) { line in
                        Text("• \(line)")
                    }
                }
                .font(.caption)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var cachedSampleDiagnosticsSection: some View {
        let diagnostics = input.package.cachedDiagnostics
        return VStack(alignment: .leading, spacing: 4) {
            Text("Cached Sample Diagnostics")
                .font(.subheadline.bold())
            Text("count: \(diagnostics.sampleCount)")
            Text("meanRGB: (\(diagnostics.meanRGB.x, specifier: "%.3f"), \(diagnostics.meanRGB.y, specifier: "%.3f"), \(diagnostics.meanRGB.z, specifier: "%.3f"))")
            Text("meanHSV: (\(diagnostics.meanHSV.x, specifier: "%.1f")°, \(diagnostics.meanHSV.y, specifier: "%.3f"), \(diagnostics.meanHSV.z, specifier: "%.3f"))")
            Text("S min/max: \(diagnostics.minSaturation, specifier: "%.3f") / \(diagnostics.maxSaturation, specifier: "%.3f")")
            Text("V min/max: \(diagnostics.minValue, specifier: "%.3f") / \(diagnostics.maxValue, specifier: "%.3f")")
            if diagnostics.hueBucketSummaries.isEmpty {
                Text("Hue buckets: (none)")
            } else {
                Text("Hue buckets: \(diagnostics.hueBucketSummaries.joined(separator: ", "))")
            }
        }
        .font(.footnote)
    }


    private var blueHueMinBinding: Binding<Float> {
        Binding(
            get: { appModel.config.blueHueRange.lowerBound },
            set: { newValue in
                let upper = max(newValue, appModel.config.blueHueRange.upperBound)
                appModel.config.blueHueRange = newValue ... upper
            }
        )
    }

    private var blueHueMaxBinding: Binding<Float> {
        Binding(
            get: { appModel.config.blueHueRange.upperBound },
            set: { newValue in
                let lower = min(newValue, appModel.config.blueHueRange.lowerBound)
                appModel.config.blueHueRange = lower ... newValue
            }
        )
    }

    private func sliderRow(label: String, value: Binding<Float>, range: ClosedRange<Float>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(label): \(value.wrappedValue, specifier: "%.3f")")
                .font(.caption)
            Slider(value: value, in: range)
        }
    }

    private func boolText(_ value: Bool) -> String {
        value ? "Y" : "N"
    }

    private func refreshInspectorScene() {
        do {
            let sourceInput = kind == .new ? appModel.newInput : appModel.usedInput
            guard let sourceInput else { return }
            inspectorScene = try SceneOverlayBuilder.makeInspectorScene(
                modelURL: sourceInput.fileURL,
                package: sourceInput.package,
                showBlue: showBluePoints,
                showRed: showRedPoints
            )
            sceneError = nil
        } catch {
            sceneError = error.localizedDescription
            inspectorScene = nil
        }
    }
}
