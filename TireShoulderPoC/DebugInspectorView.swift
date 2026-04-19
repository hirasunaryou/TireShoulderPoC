import SwiftUI
import SceneKit

struct DebugInspectorView: View {
    @EnvironmentObject private var appModel: AppModel

    let kind: ModelKind
    let input: ModelInput

    @State private var inspectorScene: SCNScene?
    @State private var roiPreviewScene: SCNScene?
    @State private var sceneError: String?
    @State private var showBluePoints = true
    @State private var showRedPoints = true

    // ROI編集用の正規化値(0...1)。
    @State private var roiNormMinX: Float = 0
    @State private var roiNormMaxX: Float = 1
    @State private var roiNormMinY: Float = 0
    @State private var roiNormMaxY: Float = 1
    @State private var roiNormMinZ: Float = 0
    @State private var roiNormMaxZ: Float = 1
    @State private var hasPendingROIChanges = false
    @State private var autoApplyROI = false
    @State private var roiApplyTask: Task<Void, Never>?
    @State private var isSyncingROI = false
    @State private var roiDeltaSummary: ROIReinspectDelta?

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
                roiEditor

                HStack {
                    Button("キャッシュから再抽出") {
                        appModel.reextractMasks(kind: kind)
                        refreshInspectorScenes()
                    }
                    .buttonStyle(.borderedProminent)

                    Spacer()
                }

                materialRecordSection
            }
        }
        .onAppear {
            syncROISlidersFromCurrentInput()
            refreshInspectorScenes()
        }
        .onChange(of: showBluePoints) { _, _ in refreshInspectorScenes() }
        .onChange(of: showRedPoints) { _, _ in refreshInspectorScenes() }
        .onChange(of: input.package.sourceBounds) { _, _ in syncROISlidersFromCurrentInput() }
        .onChange(of: input.roi) { _, _ in syncROISlidersFromCurrentInput() }
        .onDisappear { roiApplyTask?.cancel() }
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

    private var roiEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            let current = currentInput

            Text("ROI (AABB) Editor")
                .font(.subheadline.bold())

            if let roiPreviewScene {
                SceneKitOverlayView(scene: roiPreviewScene)
                    .frame(height: 180)
            }

            if hasPendingROIChanges {
                Label("未適用の変更あり", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            boundsText(title: "sourceBounds", bounds: current.package.sourceBounds)
            if let roi = current.roi {
                boundsText(title: "currentROI", bounds: roi)
            } else {
                Text("currentROI: nil (全体対象)")
                    .font(.caption)
                .foregroundStyle(.secondary)
            }
            boundsText(title: "pendingROI", bounds: pendingROI)
                .foregroundStyle(hasPendingROIChanges ? .orange : .secondary)

            roiDeltaCompactView

            roiAxisEditor(axis: "X", min: roiMinXBinding, max: roiMaxXBinding, sourceMin: current.package.sourceBounds.min.x, sourceMax: current.package.sourceBounds.max.x)
            roiAxisEditor(axis: "Y", min: roiMinYBinding, max: roiMaxYBinding, sourceMin: current.package.sourceBounds.min.y, sourceMax: current.package.sourceBounds.max.y)
            roiAxisEditor(axis: "Z", min: roiMinZBinding, max: roiMaxZBinding, sourceMin: current.package.sourceBounds.min.z, sourceMax: current.package.sourceBounds.max.z)

            Toggle("Auto Apply (デバウンス適用)", isOn: $autoApplyROI)
                .font(.caption)

            HStack {
                Button("ROIを適用") {
                    applyROI(reason: "ROI適用")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasPendingROIChanges && current.roi != nil)

                Button("ROI解除", role: .destructive) {
                    roiApplyTask?.cancel()
                    appModel.setROI(kind: kind, roi: nil)
                    syncROISlidersFromCurrentInput()
                    Task {
                        roiDeltaSummary = await appModel.reinspectModel(kind: kind, reason: "ROI解除")
                        refreshInspectorScenes()
                    }
                }
                .buttonStyle(.bordered)

                Spacer()
            }
        }
    }

    private func roiAxisEditor(axis: String,
                               min: Binding<Float>,
                               max: Binding<Float>,
                               sourceMin: Float,
                               sourceMax: Float) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            let minActual = denormalize(min.wrappedValue, sourceMin: sourceMin, sourceMax: sourceMax)
            let maxActual = denormalize(max.wrappedValue, sourceMin: sourceMin, sourceMax: sourceMax)
            Text("\(axis) min/max(norm): \(min.wrappedValue, specifier: "%.3f") / \(max.wrappedValue, specifier: "%.3f")")
                .font(.caption)
            Text("\(axis) min/max(actual): \(minActual, specifier: "%.5f") / \(maxActual, specifier: "%.5f")")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Slider(value: min, in: 0 ... 1)
            Slider(value: max, in: 0 ... 1)
        }
        .padding(.vertical, 2)
    }

    private func boundsText(title: String, bounds: SpatialBounds3D) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(title):")
                .font(.caption.bold())
            Text("min=(\(bounds.min.x, specifier: "%.5f"), \(bounds.min.y, specifier: "%.5f"), \(bounds.min.z, specifier: "%.5f"))")
                .font(.caption2)
            Text("max=(\(bounds.max.x, specifier: "%.5f"), \(bounds.max.y, specifier: "%.5f"), \(bounds.max.z, specifier: "%.5f"))")
                .font(.caption2)
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

    private var roiMinXBinding: Binding<Float> {
        Binding(get: { roiNormMinX }, set: { roiNormMinX = min($0, roiNormMaxX); handleROISliderEdited() })
    }

    private var roiMaxXBinding: Binding<Float> {
        Binding(get: { roiNormMaxX }, set: { roiNormMaxX = max($0, roiNormMinX); handleROISliderEdited() })
    }

    private var roiMinYBinding: Binding<Float> {
        Binding(get: { roiNormMinY }, set: { roiNormMinY = min($0, roiNormMaxY); handleROISliderEdited() })
    }

    private var roiMaxYBinding: Binding<Float> {
        Binding(get: { roiNormMaxY }, set: { roiNormMaxY = max($0, roiNormMinY); handleROISliderEdited() })
    }

    private var roiMinZBinding: Binding<Float> {
        Binding(get: { roiNormMinZ }, set: { roiNormMinZ = min($0, roiNormMaxZ); handleROISliderEdited() })
    }

    private var roiMaxZBinding: Binding<Float> {
        Binding(get: { roiNormMaxZ }, set: { roiNormMaxZ = max($0, roiNormMinZ); handleROISliderEdited() })
    }

    private func sliderRow(label: String, value: Binding<Float>, range: ClosedRange<Float>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(label): \(value.wrappedValue, specifier: "%.3f")")
                .font(.caption)
            Slider(value: value, in: range)
        }
    }

    private func refreshInspectorScenes() {
        do {
            let sourceInput = kind == .new ? appModel.newInput : appModel.usedInput
            guard let sourceInput else { return }
            inspectorScene = try SceneOverlayBuilder.makeInspectorScene(
                modelURL: sourceInput.fileURL,
                package: sourceInput.package,
                showBlue: showBluePoints,
                showRed: showRedPoints,
                pendingROI: hasPendingROIChanges ? pendingROI : nil,
                appliedROI: sourceInput.roi
            )
            roiPreviewScene = try SceneOverlayBuilder.makeInspectorScene(
                modelURL: sourceInput.fileURL,
                package: sourceInput.package,
                showBlue: showBluePoints,
                showRed: showRedPoints,
                pendingROI: pendingROI,
                appliedROI: sourceInput.roi
            )
            sceneError = nil
        } catch {
            sceneError = error.localizedDescription
            inspectorScene = nil
            roiPreviewScene = nil
        }
    }

    private func syncROISlidersFromCurrentInput() {
        isSyncingROI = true
        let bounds = currentInput.package.sourceBounds
        let roi = currentInput.roi ?? bounds

        roiNormMinX = normalize(roi.min.x, sourceMin: bounds.min.x, sourceMax: bounds.max.x)
        roiNormMaxX = normalize(roi.max.x, sourceMin: bounds.min.x, sourceMax: bounds.max.x)
        roiNormMinY = normalize(roi.min.y, sourceMin: bounds.min.y, sourceMax: bounds.max.y)
        roiNormMaxY = normalize(roi.max.y, sourceMin: bounds.min.y, sourceMax: bounds.max.y)
        roiNormMinZ = normalize(roi.min.z, sourceMin: bounds.min.z, sourceMax: bounds.max.z)
        roiNormMaxZ = normalize(roi.max.z, sourceMin: bounds.min.z, sourceMax: bounds.max.z)
        hasPendingROIChanges = false
        isSyncingROI = false
        refreshInspectorScenes()
    }

    private func makeROIFromCurrentSliders(sourceBounds: SpatialBounds3D) -> SpatialBounds3D {
        let minPoint = Point3(
            x: denormalize(roiNormMinX, sourceMin: sourceBounds.min.x, sourceMax: sourceBounds.max.x),
            y: denormalize(roiNormMinY, sourceMin: sourceBounds.min.y, sourceMax: sourceBounds.max.y),
            z: denormalize(roiNormMinZ, sourceMin: sourceBounds.min.z, sourceMax: sourceBounds.max.z)
        )
        let maxPoint = Point3(
            x: denormalize(roiNormMaxX, sourceMin: sourceBounds.min.x, sourceMax: sourceBounds.max.x),
            y: denormalize(roiNormMaxY, sourceMin: sourceBounds.min.y, sourceMax: sourceBounds.max.y),
            z: denormalize(roiNormMaxZ, sourceMin: sourceBounds.min.z, sourceMax: sourceBounds.max.z)
        )
        return SpatialBounds3D(min: minPoint, max: maxPoint)
    }

    private func normalize(_ value: Float, sourceMin: Float, sourceMax: Float) -> Float {
        let span = sourceMax - sourceMin
        guard span > 0 else { return 0 }
        return min(1, max(0, (value - sourceMin) / span))
    }

    private func denormalize(_ value: Float, sourceMin: Float, sourceMax: Float) -> Float {
        sourceMin + (sourceMax - sourceMin) * min(1, max(0, value))
    }

    private var currentInput: ModelInput {
        if kind == .new {
            return appModel.newInput ?? input
        }
        return appModel.usedInput ?? input
    }

    private var pendingROI: SpatialBounds3D {
        makeROIFromCurrentSliders(sourceBounds: currentInput.package.sourceBounds)
    }

    private var roiDeltaCompactView: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("ROI適用差分")
                .font(.caption.bold())
            if let delta = roiDeltaSummary {
                Text("samples: \(delta.beforeSamples) -> \(delta.afterSamples)")
                    .font(.caption2)
                Text("blue: \(delta.beforeBlue) -> \(delta.afterBlue), red: \(delta.beforeRed) -> \(delta.afterRed)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                let estimated = estimateCounts(for: pendingROI)
                Text("pending samples: \(estimated.samples), blue: \(estimated.blue), red: \(estimated.red)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func handleROISliderEdited() {
        guard !isSyncingROI else { return }
        hasPendingROIChanges = pendingROI != (currentInput.roi ?? currentInput.package.sourceBounds)
        refreshInspectorScenes()
        guard autoApplyROI, hasPendingROIChanges else { return }

        roiApplyTask?.cancel()
        roiApplyTask = Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { applyROI(reason: "Auto Apply") }
        }
    }

    private func applyROI(reason: String) {
        roiApplyTask?.cancel()
        let roi = pendingROI
        appModel.setROI(kind: kind, roi: roi)
        hasPendingROIChanges = false
        Task {
            roiDeltaSummary = await appModel.reinspectModel(kind: kind, reason: reason)
            refreshInspectorScenes()
        }
    }

    private func estimateCounts(for roi: SpatialBounds3D) -> (samples: Int, blue: Int, red: Int) {
        let package = currentInput.package
        let sampleCount = package.sampledPoints.lazy.filter { isInside($0, roi: roi) }.count
        let blueCount = package.bluePoints.lazy.filter { isInside($0, roi: roi) }.count
        let redCount = package.redPoints.lazy.filter { isInside($0, roi: roi) }.count
        return (samples: sampleCount, blue: blueCount, red: redCount)
    }

    private func isInside(_ point: Point3, roi: SpatialBounds3D) -> Bool {
        point.x >= roi.min.x && point.x <= roi.max.x &&
        point.y >= roi.min.y && point.y <= roi.max.y &&
        point.z >= roi.min.z && point.z <= roi.max.z
    }
}
