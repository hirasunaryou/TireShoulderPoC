import SwiftUI
import SceneKit

struct DebugInspectorView: View {
    @EnvironmentObject private var appModel: AppModel

    let kind: ModelKind
    let input: ModelInput

    @State private var inspectorScene: SCNScene?
    @State private var roiPreviewScene: SCNScene?
    @State private var sceneError: String?
    @State private var renderMode: InspectorRenderMode = .texturedMesh
    @State private var focusMode: InspectorFocusMode = .model
    @State private var showBluePoints = true
    @State private var showRedPoints = true
    @State private var showSampledPoints = false
    @State private var showColorRichPoints = false
    @State private var showROIBounds = false
    @State private var autoApplyROI = false
    @State private var lastDelta: ROIReinspectDelta?
    @State private var autoApplyTask: Task<Void, Never>?
    @State private var isBrushEditing = false
    @State private var brushMode: BrushPaintMode = .add
    @State private var brushInteractionMode: InteractiveSceneKitView.BrushInteractionMode = .paint
    @State private var activeBrushEditor: BrushEditorTarget = .crop
    @State private var brushRadiusMeters: Float = CropBrushState.default.radiusMeters
    @State private var brushAutoROIMarginMeters: Float = CropBrushState.default.autoROIMarginMeters
    @State private var cropBrushPreview: CropBrushPreview?
    @State private var manualRegionRole: ManualRegionRole = .alignment
    @State private var manualRegionBrushRadiusMeters: Float = ManualRegionBrushState.default.radiusMeters
    @State private var alignmentRegionPreview: ManualRegionPreview?
    @State private var comparisonRegionPreview: ManualRegionPreview?
    @State private var persistedCameraTransform: simd_float4x4?
    @State private var shouldAutoFrameOnNextRefresh = true
    @State private var latestBrushStamp: BrushStamp3D?

    // ROI編集用の正規化値(0...1)。
    @State private var roiNormMinX: Float = 0
    @State private var roiNormMaxX: Float = 1
    @State private var roiNormMinY: Float = 0
    @State private var roiNormMaxY: Float = 1
    @State private var roiNormMinZ: Float = 0
    @State private var roiNormMaxZ: Float = 1

    var body: some View {
        bindAutoApplyLifecycle(
            bindROILifecycle(
                bindSceneLifecycle(
            GroupBox("\(kind.rawValue) Debug Inspector") {
                VStack(alignment: .leading, spacing: 10) {
                    InspectorViewportSection { inspectorViewport }
                    InspectorRenderControlsSection {
                        renderAndFocusControls
                        visibilityToggles
                        maskLocatorLegend
                    }
                    InspectorStatsSection { packageStats }
                    InspectorWarningsSection { warningSection }
                    ThresholdEditorSection { thresholdEditor }
                    ROIEditorSection { roiEditor }
                    CropBrushSection { cropBrushEditor }
                    CropBrushSection { manualRegionEditor }
                    reextractButtonRow
                    MaterialInspectionSection { materialRecordSection }
                }
            }
                )
            )
        )
    }

    /// SwiftUIの型推論負荷を減らすため、ライフサイクル修飾子を責務単位で分割。
    private func bindSceneLifecycle<Content: View>(_ content: Content) -> some View {
        content
            .onAppear {
                syncROISlidersFromCurrentInput()
                syncBrushControlsFromCurrentInput()
                syncManualRegionBrushControlsFromCurrentInput()
                applyRenderModeDefaults(renderMode)
                refreshCropBrushPreview()
                refreshManualRegionPreviews()
                refreshInspectorScene()
                refreshROIPreviewScene()
            }
            .onChange(of: showBluePoints) { _, _ in refreshInspectorScene() }
            .onChange(of: showRedPoints) { _, _ in refreshInspectorScene() }
            .onChange(of: showSampledPoints) { _, _ in refreshInspectorScene() }
            .onChange(of: showColorRichPoints) { _, _ in refreshInspectorScene() }
            .onChange(of: showROIBounds) { _, _ in
                refreshInspectorScene()
                refreshROIPreviewScene()
            }
            .onDisappear {
                autoApplyTask?.cancel()
                autoApplyTask = nil
            }
    }

    /// レンダーモードやROI適用状態に追随する再描画イベントを分離。
    private func bindROILifecycle<Content: View>(_ content: Content) -> some View {
        bindROISliderLifecycle(
            bindBrushLifecycle(
                bindInspectorModeLifecycle(content)
            )
        )
    }

    /// 型推論の負荷を下げるため、onChange 群を小さな責務単位に分割する。
    private func bindInspectorModeLifecycle<Content: View>(_ content: Content) -> some View {
        content
            .onChange(of: renderMode) { _, newMode in
                applyRenderModeDefaults(newMode)
                refreshInspectorScene()
            }
            .onChange(of: focusMode) { _, _ in refreshInspectorScene() }
            .onChange(of: input.package.sourceBounds) { _, _ in
                syncROISlidersFromCurrentInput()
                refreshCropBrushPreview()
                refreshManualRegionPreviews()
                syncManualRegionBrushControlsFromCurrentInput()
                refreshInspectorScene()
                refreshROIPreviewScene()
            }
            .onChange(of: input.roi) { _, _ in
                syncROISlidersFromCurrentInput()
                refreshCropBrushPreview()
                refreshManualRegionPreviews()
                syncManualRegionBrushControlsFromCurrentInput()
                refreshInspectorScene()
                refreshROIPreviewScene()
            }
    }

    /// Brush 関連の状態変更ハンドリングを独立させる。
    private func bindBrushLifecycle<Content: View>(_ content: Content) -> some View {
        content
            .onChange(of: isBrushEditing) { _, isEditing in
                if isEditing {
                    brushInteractionMode = .paint
                    shouldAutoFrameOnNextRefresh = true
                }
                refreshInspectorScene()
            }
            .onChange(of: activeBrushEditor) { _, newEditor in
                if newEditor == .manualRegion {
                    brushAutoROIMarginMeters = currentInput.cropBrush?.autoROIMarginMeters ?? CropBrushState.default.autoROIMarginMeters
                    brushRadiusMeters = manualRegionBrushRadiusMeters
                } else {
                    syncBrushControlsFromCurrentInput()
                }
                refreshInspectorScene()
            }
            .onChange(of: brushMode) { _, _ in refreshInspectorScene() }
            .onChange(of: brushInteractionMode) { _, _ in refreshInspectorScene() }
            .onChange(of: brushRadiusMeters) { _, newValue in
                updateActiveBrushRadius(newValue)
            }
            .onChange(of: brushAutoROIMarginMeters) { _, newValue in
                updateCropBrushMargin(newValue)
            }
            .onChange(of: manualRegionRole) { _, _ in
                syncManualRegionBrushControlsFromCurrentInput()
                refreshInspectorScene()
            }
    }

    /// ROI スライダー変更イベントのみを分離し、巨大式の型推論失敗を回避する。
    private func bindROISliderLifecycle<Content: View>(_ content: Content) -> some View {
        content
            .onChange(of: roiNormMinX) { _, _ in handleROISliderChanged() }
            .onChange(of: roiNormMaxX) { _, _ in handleROISliderChanged() }
            .onChange(of: roiNormMinY) { _, _ in handleROISliderChanged() }
            .onChange(of: roiNormMaxY) { _, _ in handleROISliderChanged() }
            .onChange(of: roiNormMinZ) { _, _ in handleROISliderChanged() }
            .onChange(of: roiNormMaxZ) { _, _ in handleROISliderChanged() }
    }

    /// 自動適用のデバウンス制御だけを単独化して推論を軽くする。
    private func bindAutoApplyLifecycle<Content: View>(_ content: Content) -> some View {
        content
            .onChange(of: autoApplyROI) { _, isEnabled in
                autoApplyTask?.cancel()
                if isEnabled && hasUnappliedROIChanges {
                    scheduleAutoApply()
                }
            }
    }

    private var inspectorViewport: some View {
        Group {
            if let inspectorScene {
                ZStack(alignment: .topLeading) {
                    SceneKitOverlayView(
                        scene: inspectorScene,
                        pointOfView: inspectorScene.rootNode.childNode(withName: "InspectorCamera", recursively: true),
                        isBrushEditing: isBrushEditing,
                        brushInteractionMode: brushInteractionMode,
                        minStampDistance: max(brushRadiusMeters * 0.55, 0.0008),
                        cameraTransform: persistedCameraTransform,
                        onSurfaceHit: isBrushEditing ? { point in
                            addBrushStamp(at: point)
                        } : nil,
                        onCameraTransformChanged: { transform in
                            persistedCameraTransform = transform
                        },
                        onDoubleTapReset: {
                            fitToModel()
                        }
                    )
                    if isBrushEditing {
                        brushHelpOverlay
                    }
                }
                    .frame(height: 390)
            } else if let sceneError {
                Text(sceneError)
                    .foregroundStyle(.red)
            } else {
                ProgressView()
            }
        }
    }

    private var renderAndFocusControls: some View {
        Group {
            Picker("Render Mode", selection: $renderMode) {
                ForEach(InspectorRenderMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Picker("Focus", selection: $focusMode) {
                ForEach(InspectorFocusMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var visibilityToggles: some View {
        Group {
            Toggle("青ポイント表示", isOn: $showBluePoints)
            Toggle("赤ポイント表示", isOn: $showRedPoints)
            Toggle("Sampled points表示", isOn: $showSampledPoints)
            Toggle("Color-Rich points表示", isOn: $showColorRichPoints)
            Toggle("ROI bounds表示", isOn: $showROIBounds)
        }
    }

    private var maskLocatorLegend: some View {
        Group {
            if renderMode == .maskLocator {
                HStack(spacing: 10) {
                    Label("Candidates: \(input.package.colorRichPoints.count)", systemImage: "circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                    Label("Blue: \(input.package.bluePoints.count)", systemImage: "circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                    Label("Red: \(input.package.redPoints.count)", systemImage: "circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var packageStats: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("geometryNodes: \(input.package.geometryNodeCount)")
            Text("totalSamples: \(input.package.totalSamples)")
            Text("rawBlue/rawRed: \(input.package.rawBlueCount) / \(input.package.rawRedCount)")
            Text("reducedBlue/reducedRed: \(input.package.bluePoints.count) / \(input.package.redPoints.count)")
            Text("skippedNoUVTriangles: \(input.package.skippedNoUVTriangles)")
            Text("cachedSamples: \(input.package.cachedSamples.count)")
        }
        .font(.footnote)
    }

    private var warningSection: some View {
        Group {
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
        }
    }

    private var reextractButtonRow: some View {
        HStack {
            Button("キャッシュから再抽出") {
                appModel.reextractMasks(kind: kind)
                refreshInspectorScene()
            }
            .buttonStyle(.borderedProminent)

            Spacer()
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

    private var roiEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            let current = currentInput

            Text("ROI (AABB) Editor")
                .font(.subheadline.bold())

            if let roiPreviewScene {
                SceneKitOverlayView(scene: roiPreviewScene)
                    .frame(height: 190)
                roiLegend
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

            if hasUnappliedROIChanges {
                Text("未適用の変更あり（スライダー変更だけでは再解析されません）")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text("未適用の変更なし")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("Auto Apply (デバウンス)", isOn: $autoApplyROI)
                .font(.caption)

            if let lastDelta {
                Text("ROI適用結果: \(lastDelta.compactText)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            roiAxisEditor(axis: "X", min: roiMinXBinding, max: roiMaxXBinding, sourceMin: current.package.sourceBounds.min.x, sourceMax: current.package.sourceBounds.max.x)
            roiAxisEditor(axis: "Y", min: roiMinYBinding, max: roiMaxYBinding, sourceMin: current.package.sourceBounds.min.y, sourceMax: current.package.sourceBounds.max.y)
            roiAxisEditor(axis: "Z", min: roiMinZBinding, max: roiMaxZBinding, sourceMin: current.package.sourceBounds.min.z, sourceMax: current.package.sourceBounds.max.z)

            HStack {
                Button("ROIを適用") {
                    applyPendingROI(reason: "ROI適用")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasUnappliedROIChanges && !autoApplyROI)

                Button("ROI解除", role: .destructive) {
                    appModel.setROI(kind: kind, roi: nil)
                    syncROISlidersFromCurrentInput()
                    Task {
                        lastDelta = await appModel.reinspectModel(kind: kind, reason: "ROI解除")
                        refreshInspectorScene()
                        refreshROIPreviewScene()
                    }
                }
                .buttonStyle(.bordered)

                Spacer()
            }
        }
    }

    private var roiLegend: some View {
        HStack(spacing: 10) {
            Label("適用済ROI", systemImage: "square.dashed")
                .font(.caption2)
                .foregroundStyle(.green)
            Label("未適用pendingROI", systemImage: "square.dashed.inset.filled")
                .font(.caption2)
                .foregroundStyle(.orange)
            Spacer()
        }
    }

    private var cropBrushEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Crop Brush (MVP)")
                .font(.subheadline.bold())

            Toggle("Brush編集モード", isOn: $isBrushEditing)
            if isBrushEditing {
                Text(activeBrushEditor == .crop ? "Editing: Crop Brush" : "Editing: Manual Region (\(manualRegionRole.rawValue))")
                    .font(.caption.bold())
                Picker("Interaction", selection: $brushInteractionMode) {
                    Text("Paint").tag(InteractiveSceneKitView.BrushInteractionMode.paint)
                    Text("Navigate").tag(InteractiveSceneKitView.BrushInteractionMode.navigate)
                }
                .pickerStyle(.segmented)
            }
            Picker("Paint", selection: $brushMode) {
                Text("Add").tag(BrushPaintMode.add)
                Text("Erase").tag(BrushPaintMode.erase)
            }
            .pickerStyle(.segmented)
            Picker("Editor", selection: $activeBrushEditor) {
                Text("Crop").tag(BrushEditorTarget.crop)
                Text("Manual Region").tag(BrushEditorTarget.manualRegion)
            }
            .pickerStyle(.segmented)
            fitButtonRow

            sliderRow(label: "Brush Radius [m]", value: $brushRadiusMeters, range: 0.001 ... 0.02)
            sliderRow(label: "Auto ROI Margin [m]", value: $brushAutoROIMarginMeters, range: 0.001 ... 0.02)

            if let preview = cropBrushPreview {
                Text("selected samples: \(preview.selectedSampleCount)")
                    .font(.caption)
                if let autoROI = preview.autoROI {
                    boundsText(title: "brushAutoROI", bounds: autoROI)
                } else {
                    Text("brushAutoROI: nil (未選択)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("selected samples: 0")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("BrushからROI適用") {
                    Task {
                        lastDelta = await appModel.applyCropBrushAsROI(kind: kind)
                        refreshCropBrushPreview()
                        refreshInspectorScene()
                        refreshROIPreviewScene()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(cropBrushPreview?.autoROI == nil)

                Button("Brushクリア", role: .destructive) {
                    appModel.clearCropBrush(kind: kind)
                    refreshCropBrushPreview()
                    refreshInspectorScene()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var manualRegionEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Manual Regions (MVP)")
                .font(.subheadline.bold())
            Picker("編集対象", selection: $manualRegionRole) {
                ForEach(ManualRegionRole.allCases) { role in
                    Text(role.rawValue).tag(role)
                }
            }
            .pickerStyle(.segmented)
            Text("※ Crop Brush と同時編集しないため、上の Editor で Manual Region を選択してください。")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("自動青/赤が弱い場合でも、塗った sampled surface をそのまま位置合わせ/比較に使います。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            sliderRow(label: "Manual Brush Radius [m]", value: manualBrushRadiusBinding, range: 0.001 ... 0.02)

            let preview = manualRegionRole == .alignment ? alignmentRegionPreview : comparisonRegionPreview
            if let preview {
                Text("selected sample count: \(preview.selectedCount)")
                    .font(.caption)
                Text(preview.role == .alignment
                     ? "effective alignment points: \(preview.effectivePointCount)"
                     : "effective comparison points: \(preview.effectivePointCount)")
                    .font(.caption)
                if preview.selectedCount < appModel.config.minimumMaskPoints {
                    Text(warningText(for: preview.role, selectedCount: preview.selectedCount))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            } else {
                Text("selected sample count: 0")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(manualRegionRole == .alignment
                     ? "effective alignment points: 0"
                     : "effective comparison points: 0")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("比較前サマリ")
                    .font(.caption.bold())
                manualSummaryRow(role: .alignment, title: "Alignment")
                manualSummaryRow(role: .comparison, title: "Comparison")
            }

            HStack {
                Button("クリア", role: .destructive) {
                    clearCurrentManualRegionBrush()
                    refreshManualRegionPreviews()
                    refreshInspectorScene()
                }
                .buttonStyle(.bordered)
                Spacer()
            }
        }
    }

    private var fitButtonRow: some View {
        HStack(spacing: 8) {
            Button("Fit Model") { fitToModel() }
                .buttonStyle(.bordered)
            Button("Fit ROI") { fitToROI() }
                .buttonStyle(.bordered)
            Button("Fit Brush") { fitToBrush() }
                .buttonStyle(.borderedProminent)
            Button("Reset View") { fitToModel() }
                .buttonStyle(.bordered)
        }
        .font(.caption)
    }

    private var brushHelpOverlay: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("1本指: 塗る")
            Text("2本指: 視点移動")
            Text("Pinch: 拡大縮小")
            Text("Double Tap: Reset")
        }
        .font(.caption2)
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(10)
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
        Binding(get: { roiNormMinX }, set: { roiNormMinX = min($0, roiNormMaxX) })
    }

    private var manualBrushRadiusBinding: Binding<Float> {
        Binding(
            get: { manualRegionBrushRadiusMeters },
            set: { newValue in
                manualRegionBrushRadiusMeters = newValue
                if activeBrushEditor == .manualRegion {
                    brushRadiusMeters = newValue
                }
                updateManualRegionBrushRadius(newValue)
            }
        )
    }

    private var roiMaxXBinding: Binding<Float> {
        Binding(get: { roiNormMaxX }, set: { roiNormMaxX = max($0, roiNormMinX) })
    }

    private var roiMinYBinding: Binding<Float> {
        Binding(get: { roiNormMinY }, set: { roiNormMinY = min($0, roiNormMaxY) })
    }

    private var roiMaxYBinding: Binding<Float> {
        Binding(get: { roiNormMaxY }, set: { roiNormMaxY = max($0, roiNormMinY) })
    }

    private var roiMinZBinding: Binding<Float> {
        Binding(get: { roiNormMinZ }, set: { roiNormMinZ = min($0, roiNormMaxZ) })
    }

    private var roiMaxZBinding: Binding<Float> {
        Binding(get: { roiNormMaxZ }, set: { roiNormMaxZ = max($0, roiNormMinZ) })
    }

    private func sliderRow(label: String, value: Binding<Float>, range: ClosedRange<Float>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(label): \(value.wrappedValue, specifier: "%.3f")")
                .font(.caption)
            Slider(value: value, in: range)
        }
    }

    private func refreshInspectorScene() {
        do {
            let sourceInput = kind == .new ? appModel.newInput : appModel.usedInput
            guard let sourceInput else { return }
            let shouldFrame = shouldAutoFrameOnNextRefresh
            let framingScale: Float = (isBrushEditing && shouldFrame) ? 0.72 : 1.0
            let options = makeInspectorOptions(sourceInput: sourceInput, framingScale: framingScale)
            inspectorScene = try SceneOverlayBuilder.makeInspectorScene(
                modelURL: sourceInput.fileURL,
                package: sourceInput.package,
                options: options
            )
            if shouldFrame {
                let target = preferredBrushStartBounds(from: sourceInput) ?? focusBounds(for: sourceInput) ?? sourceInput.package.sourceBounds
                persistedCameraTransform = SceneOverlayBuilder.makeFramingCamera(bounds: target, distanceScale: framingScale).simdTransform
                shouldAutoFrameOnNextRefresh = false
            }
            sceneError = nil
        } catch {
            sceneError = error.localizedDescription
            inspectorScene = nil
        }
    }

    private func refreshROIPreviewScene() {
        do {
            let sourceInput = kind == .new ? appModel.newInput : appModel.usedInput
            guard let sourceInput else { return }
            let options = makeROIPreviewOptions(sourceInput: sourceInput)
            roiPreviewScene = try SceneOverlayBuilder.makeInspectorScene(
                modelURL: sourceInput.fileURL,
                package: sourceInput.package,
                options: options
            )
            sceneError = nil
        } catch {
            sceneError = error.localizedDescription
            roiPreviewScene = nil
        }
    }

    private func makeInspectorOptions(sourceInput: ModelInput, framingScale: Float) -> InspectorSceneOptions {
        InspectorSceneOptions(
            renderMode: renderMode,
            focusMode: focusMode,
            showBlue: showBluePoints,
            showRed: showRedPoints,
            showSampledPoints: showSampledPoints,
            showColorRichPoints: showColorRichPoints,
            showROIBounds: showROIBounds,
            selectedBrushPoints: cropBrushPreview?.selectedPoints ?? [],
            alignmentRegionPoints: alignmentRegionPreview?.selectedPoints ?? [],
            comparisonRegionPoints: comparisonRegionPreview?.selectedPoints ?? [],
            recentBrushStamp: latestBrushStamp,
            brushAutoROI: cropBrushPreview?.autoROI,
            pendingROI: pendingROI,
            appliedROI: sourceInput.roi,
            framingDistanceScale: framingScale
        )
    }

    private func makeROIPreviewOptions(sourceInput: ModelInput) -> InspectorSceneOptions {
        InspectorSceneOptions(
            renderMode: .texturedMesh,
            focusMode: .roi,
            showBlue: true,
            showRed: true,
            showSampledPoints: false,
            showColorRichPoints: false,
            showROIBounds: true,
            selectedBrushPoints: cropBrushPreview?.selectedPoints ?? [],
            alignmentRegionPoints: alignmentRegionPreview?.selectedPoints ?? [],
            comparisonRegionPoints: comparisonRegionPreview?.selectedPoints ?? [],
            recentBrushStamp: nil,
            brushAutoROI: cropBrushPreview?.autoROI,
            pendingROI: pendingROI,
            appliedROI: sourceInput.roi,
            framingDistanceScale: 1.0
        )
    }

    private func syncROISlidersFromCurrentInput() {
        let bounds = currentInput.package.sourceBounds
        let roi = currentInput.roi ?? bounds

        roiNormMinX = normalize(roi.min.x, sourceMin: bounds.min.x, sourceMax: bounds.max.x)
        roiNormMaxX = normalize(roi.max.x, sourceMin: bounds.min.x, sourceMax: bounds.max.x)
        roiNormMinY = normalize(roi.min.y, sourceMin: bounds.min.y, sourceMax: bounds.max.y)
        roiNormMaxY = normalize(roi.max.y, sourceMin: bounds.min.y, sourceMax: bounds.max.y)
        roiNormMinZ = normalize(roi.min.z, sourceMin: bounds.min.z, sourceMax: bounds.max.z)
        roiNormMaxZ = normalize(roi.max.z, sourceMin: bounds.min.z, sourceMax: bounds.max.z)
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

    private func handleROISliderChanged() {
        refreshROIPreviewScene()
        if autoApplyROI {
            scheduleAutoApply()
        }
    }

    private func scheduleAutoApply() {
        autoApplyTask?.cancel()
        autoApplyTask = Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                applyPendingROI(reason: "Auto Apply")
            }
        }
    }

    private func applyPendingROI(reason: String) {
        let roi = pendingROI
        appModel.setROI(kind: kind, roi: roi)
        Task {
            lastDelta = await appModel.reinspectModel(kind: kind, reason: reason)
            refreshInspectorScene()
            refreshROIPreviewScene()
        }
    }

    private func syncBrushControlsFromCurrentInput() {
        let brush = currentInput.cropBrush ?? .default
        brushRadiusMeters = brush.radiusMeters
        brushAutoROIMarginMeters = brush.autoROIMarginMeters
    }

    private func syncManualRegionBrushControlsFromCurrentInput() {
        let brush: ManualRegionBrushState?
        switch manualRegionRole {
        case .alignment:
            brush = currentInput.alignmentBrush
        case .comparison:
            brush = currentInput.comparisonBrush
        }
        manualRegionBrushRadiusMeters = brush?.radiusMeters ?? ManualRegionBrushState.default.radiusMeters
        if activeBrushEditor == .manualRegion {
            brushRadiusMeters = manualRegionBrushRadiusMeters
        }
    }

    private func refreshCropBrushPreview() {
        cropBrushPreview = appModel.previewCropBrushSelection(kind: kind)
    }

    private func refreshManualRegionPreviews() {
        alignmentRegionPreview = appModel.previewAlignmentBrush(kind: kind)
        comparisonRegionPreview = appModel.previewComparisonBrush(kind: kind)
    }

    private func addBrushStamp(at point: Point3) {
        if activeBrushEditor == .manualRegion {
            addManualRegionBrushStamp(at: point)
            return
        }
        var brush = currentInput.cropBrush ?? CropBrushState.default
        brush.radiusMeters = brushRadiusMeters
        brush.autoROIMarginMeters = brushAutoROIMarginMeters
        let newStamp = BrushStamp3D(center: point, radiusMeters: brushRadiusMeters, mode: brushMode)
        brush.stamps.append(newStamp)
        appModel.setCropBrush(kind: kind, brush: brush)
        latestBrushStamp = newStamp
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            if latestBrushStamp?.id == newStamp.id {
                latestBrushStamp = nil
                refreshInspectorScene()
            }
        }
        refreshCropBrushPreview()
        refreshInspectorScene()
        refreshROIPreviewScene()
    }

    private func addManualRegionBrushStamp(at point: Point3) {
        var brush = currentManualRegionBrush() ?? ManualRegionBrushState.default
        brush.radiusMeters = manualRegionBrushRadiusMeters
        brush.isEnabled = true
        let newStamp = BrushStamp3D(center: point, radiusMeters: manualRegionBrushRadiusMeters, mode: brushMode)
        brush.stamps.append(newStamp)
        persistManualRegionBrush(brush)
        latestBrushStamp = newStamp
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            if latestBrushStamp?.id == newStamp.id {
                latestBrushStamp = nil
                refreshInspectorScene()
            }
        }
        refreshManualRegionPreviews()
        refreshInspectorScene()
    }

    private func updateActiveBrushRadius(_ radius: Float) {
        if activeBrushEditor == .manualRegion {
            updateManualRegionBrushRadius(radius)
        } else {
            updateCropBrushRadius(radius)
        }
    }

    private func updateCropBrushRadius(_ radius: Float) {
        var brush = currentInput.cropBrush ?? CropBrushState.default
        brush.radiusMeters = radius
        appModel.setCropBrush(kind: kind, brush: brush)
        refreshCropBrushPreview()
        refreshInspectorScene()
    }

    private func updateCropBrushMargin(_ margin: Float) {
        var brush = currentInput.cropBrush ?? CropBrushState.default
        brush.autoROIMarginMeters = margin
        appModel.setCropBrush(kind: kind, brush: brush)
        refreshCropBrushPreview()
        refreshInspectorScene()
    }

    private func updateManualRegionBrushRadius(_ radius: Float) {
        manualRegionBrushRadiusMeters = radius
        var brush = currentManualRegionBrush() ?? ManualRegionBrushState.default
        brush.radiusMeters = radius
        brush.isEnabled = true
        persistManualRegionBrush(brush)
        refreshManualRegionPreviews()
        refreshInspectorScene()
    }

    private func currentManualRegionBrush() -> ManualRegionBrushState? {
        switch manualRegionRole {
        case .alignment:
            return currentInput.alignmentBrush
        case .comparison:
            return currentInput.comparisonBrush
        }
    }

    private func persistManualRegionBrush(_ brush: ManualRegionBrushState?) {
        switch manualRegionRole {
        case .alignment:
            appModel.setAlignmentBrush(kind: kind, brush: brush)
        case .comparison:
            appModel.setComparisonBrush(kind: kind, brush: brush)
        }
    }

    private func clearCurrentManualRegionBrush() {
        switch manualRegionRole {
        case .alignment:
            appModel.clearAlignmentBrush(kind: kind)
        case .comparison:
            appModel.clearComparisonBrush(kind: kind)
        }
    }

    private func manualSummaryRow(role: ManualRegionRole, title: String) -> some View {
        let preview = role == .alignment ? alignmentRegionPreview : comparisonRegionPreview
        let selectedCount = preview?.selectedCount ?? 0
        let effectiveCount = preview?.effectivePointCount ?? 0
        return Text(role == .alignment
                    ? "\(title): selected \(selectedCount), effective blue \(effectiveCount)"
                    : "\(title): selected \(selectedCount), effective red \(effectiveCount)")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    private func warningText(for role: ManualRegionRole, selectedCount: Int) -> String {
        let minimum = appModel.config.minimumMaskPoints
        switch role {
        case .alignment:
            return "Alignment Region は最低 \(minimum) 点必要です（現在 \(selectedCount)）"
        case .comparison:
            return "Comparison Region は最低 \(minimum) 点必要です（現在 \(selectedCount)）"
        }
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

    private var hasUnappliedROIChanges: Bool {
        let sourceBounds = currentInput.package.sourceBounds
        let applied = currentInput.roi ?? sourceBounds
        return !approximatelyEqual(applied, pendingROI)
    }

    private func approximatelyEqual(_ lhs: SpatialBounds3D, _ rhs: SpatialBounds3D, epsilon: Float = 0.000_001) -> Bool {
        abs(lhs.min.x - rhs.min.x) < epsilon &&
        abs(lhs.min.y - rhs.min.y) < epsilon &&
        abs(lhs.min.z - rhs.min.z) < epsilon &&
        abs(lhs.max.x - rhs.max.x) < epsilon &&
        abs(lhs.max.y - rhs.max.y) < epsilon &&
        abs(lhs.max.z - rhs.max.z) < epsilon
    }

    private func applyRenderModeDefaults(_ mode: InspectorRenderMode) {
        // モード切替時に「まず見たい状態」へ戻すデフォルトを定義。
        switch mode {
        case .texturedMesh:
            showSampledPoints = false
            showColorRichPoints = false
            showBluePoints = true
            showRedPoints = true
        case .sampledRGB:
            showSampledPoints = false
            showColorRichPoints = false
            showBluePoints = true
            showRedPoints = true
        case .maskLocator:
            showSampledPoints = false
            showColorRichPoints = true
            showBluePoints = true
            showRedPoints = true
        }
    }

    private func fitToModel() {
        let bounds = currentInput.package.sourceBounds
        persistedCameraTransform = SceneOverlayBuilder.makeFramingCamera(bounds: bounds, distanceScale: 0.86).simdTransform
    }

    private func fitToROI() {
        let target = pendingROIForFit ?? currentInput.roi ?? currentInput.package.sourceBounds
        persistedCameraTransform = SceneOverlayBuilder.makeFramingCamera(bounds: target, distanceScale: 0.84).simdTransform
    }

    private func fitToBrush() {
        let target = cropBrushPreview?.selectedPointsBounds
            ?? cropBrushPreview?.autoROI
            ?? pendingROIForFit
            ?? currentInput.roi
            ?? currentInput.package.sourceBounds
        persistedCameraTransform = SceneOverlayBuilder.makeFramingCamera(bounds: target, distanceScale: 0.8).simdTransform
    }

    private var pendingROIForFit: SpatialBounds3D? {
        hasUnappliedROIChanges ? pendingROI : nil
    }

    private func preferredBrushStartBounds(from input: ModelInput) -> SpatialBounds3D? {
        if activeBrushEditor == .manualRegion {
            let points: [Point3]?
            switch manualRegionRole {
            case .alignment:
                points = alignmentRegionPreview?.selectedPoints
            case .comparison:
                points = comparisonRegionPreview?.selectedPoints
            }
            if let points, let bounds = SpatialBounds3D(points: points.map(\.simd)) {
                return bounds
            }
        }
        if let autoROI = cropBrushPreview?.autoROI {
            return autoROI
        }
        if hasUnappliedROIChanges {
            return pendingROI
        }
        if let inputROI = input.roi {
            return inputROI
        }
        return input.package.sourceBounds
    }

    private func focusBounds(for input: ModelInput) -> SpatialBounds3D? {
        switch focusMode {
        case .model:
            return input.package.sourceBounds
        case .roi:
            return pendingROIForFit ?? input.roi
        case .colorRich:
            return SpatialBounds3D(points: input.package.colorRichPoints.map(\.simd))
        case .blue:
            return SpatialBounds3D(points: input.package.bluePoints.map(\.simd))
        case .red:
            return SpatialBounds3D(points: input.package.redPoints.map(\.simd))
        }
    }
}

private enum BrushEditorTarget: String, CaseIterable, Hashable {
    case crop
    case manualRegion
}

private extension CropBrushPreview {
    var selectedPointsBounds: SpatialBounds3D? {
        SpatialBounds3D(points: selectedPoints.map(\.simd))
    }
}

private struct InspectorViewportSection<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
    }
}

private struct InspectorRenderControlsSection<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
    }
}

private struct InspectorStatsSection<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
    }
}

private struct InspectorWarningsSection<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
    }
}

private struct ThresholdEditorSection<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
    }
}

private struct ROIEditorSection<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
    }
}

private struct CropBrushSection<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
    }
}

private struct MaterialInspectionSection<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
    }
}
