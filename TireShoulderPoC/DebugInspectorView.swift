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
    @State private var roiXMinNorm: Float = 0
    @State private var roiXMaxNorm: Float = 1
    @State private var roiYMinNorm: Float = 0
    @State private var roiYMaxNorm: Float = 1
    @State private var roiZMinNorm: Float = 0
    @State private var roiZMaxNorm: Float = 1

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
                roiEditorSection

                HStack {
                    Button("キャッシュから再抽出") {
                        appModel.reextractMasks(kind: kind)
                        refreshInspectorScene()
                    }
                    .buttonStyle(.borderedProminent)

                    Spacer()
                }

                materialRecordSection
            }
        }
        .onAppear { refreshInspectorScene() }
        .onAppear { syncROIEditorFromModel() }
        .onChange(of: showBluePoints) { _, _ in refreshInspectorScene() }
        .onChange(of: showRedPoints) { _, _ in refreshInspectorScene() }
        .onChange(of: roiEditorSyncKey) { _, _ in
            syncROIEditorFromModel()
        }
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
            Text("Material Inspection")
                .font(.subheadline.bold())

            ForEach(input.package.materialRecords) { record in
                VStack(alignment: .leading, spacing: 2) {
                    Text("node=\(record.nodeName), geo=\(record.geometryName), matIdx=\(record.materialIndex)")
                    Text("UV=\(record.hasUV ? "Y" : "N"), VColor=\(record.hasVertexColor ? "Y" : "N"), triangles=\(record.triangleCount), sampled=\(record.sampledTriangleCount)")
                    Text("texture=\(record.textureSourceSummary)")
                }
                .font(.caption)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
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

    private var roiEditorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ROI (AABB) Editor")
                .font(.subheadline.bold())

            VStack(alignment: .leading, spacing: 2) {
                Text("sourceBounds:")
                    .font(.caption.bold())
                Text(boundsDescription(input.package.sourceBounds))
                    .font(.caption.monospaced())
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("current ROI:")
                    .font(.caption.bold())
                Text(input.roi.map(boundsDescription) ?? "nil (全領域)")
                    .font(.caption.monospaced())
            }

            axisSliderRows(axisLabel: "X", minValue: xMinBinding, maxValue: xMaxBinding)
            axisSliderRows(axisLabel: "Y", minValue: yMinBinding, maxValue: yMaxBinding)
            axisSliderRows(axisLabel: "Z", minValue: zMinBinding, maxValue: zMaxBinding)

            HStack {
                Button("ROI適用") {
                    appModel.updateROI(kind: kind, roi: roiFromNormalizedEditor())
                    Task {
                        await appModel.reinspectModel(kind: kind)
                        refreshInspectorScene()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(appModel.isBusy)

                Button("ROI解除") {
                    appModel.updateROI(kind: kind, roi: nil)
                    syncROIEditorFromModel()
                    Task {
                        await appModel.reinspectModel(kind: kind)
                        refreshInspectorScene()
                    }
                }
                .buttonStyle(.bordered)
                .disabled(appModel.isBusy)
            }
        }
    }

    private func axisSliderRows(axisLabel: String, minValue: Binding<Float>, maxValue: Binding<Float>) -> some View {
        let sourceBounds = input.package.sourceBounds
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(axisLabel) min/max (normalized 0...1)")
                .font(.caption.bold())
            Slider(value: minValue, in: 0 ... 1)
            Slider(value: maxValue, in: 0 ... 1)
            Text(
                "\(axisLabel): n[\(minValue.wrappedValue, specifier: "%.3f"), \(maxValue.wrappedValue, specifier: "%.3f")] " +
                "→ w[\(actualCoordinate(for: axisLabel, normalized: minValue.wrappedValue, sourceBounds: sourceBounds), specifier: "%.4f"), " +
                "\(actualCoordinate(for: axisLabel, normalized: maxValue.wrappedValue, sourceBounds: sourceBounds), specifier: "%.4f")]"
            )
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
        }
    }

    private var xMinBinding: Binding<Float> {
        Binding(
            get: { roiXMinNorm },
            set: { newValue in
                roiXMinNorm = min(newValue, roiXMaxNorm)
            }
        )
    }

    private var xMaxBinding: Binding<Float> {
        Binding(
            get: { roiXMaxNorm },
            set: { newValue in
                roiXMaxNorm = max(newValue, roiXMinNorm)
            }
        )
    }

    private var yMinBinding: Binding<Float> {
        Binding(
            get: { roiYMinNorm },
            set: { newValue in
                roiYMinNorm = min(newValue, roiYMaxNorm)
            }
        )
    }

    private var yMaxBinding: Binding<Float> {
        Binding(
            get: { roiYMaxNorm },
            set: { newValue in
                roiYMaxNorm = max(newValue, roiYMinNorm)
            }
        )
    }

    private var zMinBinding: Binding<Float> {
        Binding(
            get: { roiZMinNorm },
            set: { newValue in
                roiZMinNorm = min(newValue, roiZMaxNorm)
            }
        )
    }

    private var zMaxBinding: Binding<Float> {
        Binding(
            get: { roiZMaxNorm },
            set: { newValue in
                roiZMaxNorm = max(newValue, roiZMinNorm)
            }
        )
    }

    /// 現在のモデル入力の `sourceBounds + roi` から、UI編集値へ同期するためのキー。
    private var roiEditorSyncKey: String {
        let s = input.package.sourceBounds
        let r = input.roi
        return [
            s.min.x, s.min.y, s.min.z,
            s.max.x, s.max.y, s.max.z,
            r?.min.x, r?.min.y, r?.min.z,
            r?.max.x, r?.max.y, r?.max.z
        ]
        .map { value in
            guard let value else { return "nil" }
            return String(format: "%.6f", value)
        }
        .joined(separator: "|")
    }

    private func syncROIEditorFromModel() {
        let source = input.package.sourceBounds
        let roi = input.roi ?? source
        roiXMinNorm = normalizedCoordinate(roi.min.x, min: source.min.x, max: source.max.x)
        roiXMaxNorm = normalizedCoordinate(roi.max.x, min: source.min.x, max: source.max.x)
        roiYMinNorm = normalizedCoordinate(roi.min.y, min: source.min.y, max: source.max.y)
        roiYMaxNorm = normalizedCoordinate(roi.max.y, min: source.min.y, max: source.max.y)
        roiZMinNorm = normalizedCoordinate(roi.min.z, min: source.min.z, max: source.max.z)
        roiZMaxNorm = normalizedCoordinate(roi.max.z, min: source.min.z, max: source.max.z)
    }

    private func roiFromNormalizedEditor() -> SpatialBounds3D {
        let s = input.package.sourceBounds
        return SpatialBounds3D(
            min: Point3(
                x: actualCoordinate(for: "X", normalized: roiXMinNorm, sourceBounds: s),
                y: actualCoordinate(for: "Y", normalized: roiYMinNorm, sourceBounds: s),
                z: actualCoordinate(for: "Z", normalized: roiZMinNorm, sourceBounds: s)
            ),
            max: Point3(
                x: actualCoordinate(for: "X", normalized: roiXMaxNorm, sourceBounds: s),
                y: actualCoordinate(for: "Y", normalized: roiYMaxNorm, sourceBounds: s),
                z: actualCoordinate(for: "Z", normalized: roiZMaxNorm, sourceBounds: s)
            )
        )
    }

    private func normalizedCoordinate(_ value: Float, min: Float, max: Float) -> Float {
        let span = max - min
        guard abs(span) > .ulpOfOne else { return 0 }
        return ((value - min) / span).clamped(to: 0 ... 1)
    }

    private func actualCoordinate(for axisLabel: String, normalized: Float, sourceBounds: SpatialBounds3D) -> Float {
        switch axisLabel {
        case "X":
            return denormalize(normalized: normalized, min: sourceBounds.min.x, max: sourceBounds.max.x)
        case "Y":
            return denormalize(normalized: normalized, min: sourceBounds.min.y, max: sourceBounds.max.y)
        default:
            return denormalize(normalized: normalized, min: sourceBounds.min.z, max: sourceBounds.max.z)
        }
    }

    private func denormalize(normalized: Float, min: Float, max: Float) -> Float {
        min + (max - min) * normalized
    }

    private func boundsDescription(_ bounds: SpatialBounds3D) -> String {
        let minText = "min(\(bounds.min.x, specifier: "%.4f"), \(bounds.min.y, specifier: "%.4f"), \(bounds.min.z, specifier: "%.4f"))"
        let maxText = "max(\(bounds.max.x, specifier: "%.4f"), \(bounds.max.y, specifier: "%.4f"), \(bounds.max.z, specifier: "%.4f"))"
        return "\(minText), \(maxText)"
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
