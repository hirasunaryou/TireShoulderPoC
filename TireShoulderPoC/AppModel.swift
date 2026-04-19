import Foundation
import SceneKit
import SwiftUI

struct ROIReinspectDelta: Sendable {
    let beforeSamples: Int
    let afterSamples: Int
    let beforeBlue: Int
    let afterBlue: Int
    let beforeRed: Int
    let afterRed: Int

    init(before: LoadedModelPackage, after: LoadedModelPackage) {
        beforeSamples = before.totalSamples
        afterSamples = after.totalSamples
        beforeBlue = before.bluePoints.count
        afterBlue = after.bluePoints.count
        beforeRed = before.redPoints.count
        afterRed = after.redPoints.count
    }

    var compactText: String {
        "samples: \(beforeSamples) -> \(afterSamples), blue: \(beforeBlue) -> \(afterBlue), red: \(beforeRed) -> \(afterRed)"
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var newInput: ModelInput?
    @Published var usedInput: ModelInput?
    @Published var analysisResult: ComparisonResult?
    @Published var overlayScene: SCNScene?
    @Published var statusMessage: String = "新品と走行品のUSDZを読み込んでください。"
    @Published var errorMessage: String?
    @Published var isBusy = false
    @Published var exportedCSVURL: URL?

    // デバッグUIから直接しきい値をいじれるように可変の設定として公開する。
    @Published var config = AnalysisConfig()

    var canCompare: Bool {
        guard let newInput, let usedInput else { return false }
        let minPoints = config.minimumMaskPoints
        return newInput.package.bluePoints.count >= minPoints
            && newInput.package.redPoints.count >= minPoints
            && usedInput.package.bluePoints.count >= minPoints
            && usedInput.package.redPoints.count >= minPoints
    }

    func importModel(kind: ModelKind, from pickedURL: URL) async {
        isBusy = true
        errorMessage = nil
        exportedCSVURL = nil
        analysisResult = nil
        overlayScene = nil
        statusMessage = "\(kind.rawValue) USDZを解析中..."

        do {
            let localURL = try LocalFileStore.importCopy(from: pickedURL, preferredName: pickedURL.lastPathComponent)
            let config = self.config

            let package = try await Task.detached(priority: .userInitiated) {
                try USDZLoader.inspect(url: localURL, config: config, roi: nil)
            }.value

            let input = ModelInput(
                kind: kind,
                fileURL: localURL,
                roi: nil,
                cropBrush: nil,
                alignmentBrush: nil,
                comparisonBrush: nil,
                package: package
            )

            switch kind {
            case .new:
                newInput = input
            case .used:
                usedInput = input
            }

            statusMessage = makeImportSummary(kind: kind, package: package)
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "読み込みに失敗しました。"
        }

        isBusy = false
    }

    func reextractMasks(kind: ModelKind) {
        switch kind {
        case .new:
            guard var input = newInput else { return }
            input.package = USDZLoader.reextractMasks(from: input.package, config: config)
            newInput = input
            statusMessage = "新品: キャッシュ済みサンプルから再抽出しました。青 \(input.package.bluePoints.count) / 赤 \(input.package.redPoints.count)"
        case .used:
            guard var input = usedInput else { return }
            input.package = USDZLoader.reextractMasks(from: input.package, config: config)
            usedInput = input
            statusMessage = "走行品: キャッシュ済みサンプルから再抽出しました。青 \(input.package.bluePoints.count) / 赤 \(input.package.redPoints.count)"
        }
    }

    func setCropBrush(kind: ModelKind, brush: CropBrushState?) {
        guard var input = modelInput(for: kind) else { return }
        input.cropBrush = brush
        setModelInput(input, for: kind)
    }

    func clearCropBrush(kind: ModelKind) {
        setCropBrush(kind: kind, brush: nil)
    }

    func setAlignmentBrush(kind: ModelKind, brush: ManualRegionBrushState?) {
        guard var input = modelInput(for: kind) else { return }
        input.alignmentBrush = brush
        setModelInput(input, for: kind)
    }

    func setComparisonBrush(kind: ModelKind, brush: ManualRegionBrushState?) {
        guard var input = modelInput(for: kind) else { return }
        input.comparisonBrush = brush
        setModelInput(input, for: kind)
    }

    func clearAlignmentBrush(kind: ModelKind) {
        setAlignmentBrush(kind: kind, brush: nil)
    }

    func clearComparisonBrush(kind: ModelKind) {
        setComparisonBrush(kind: kind, brush: nil)
    }

    func previewCropBrushSelection(kind: ModelKind) -> CropBrushPreview? {
        guard let input = modelInput(for: kind), let brush = input.cropBrush else { return nil }
        return CropBrushEngine.makePreview(samples: input.package.cachedSamples, brush: brush)
    }

    func previewAlignmentBrush(kind: ModelKind) -> ManualRegionPreview? {
        guard let input = modelInput(for: kind), let brush = input.alignmentBrush else { return nil }
        return CropBrushEngine.makeManualRegionPreview(
            samples: input.package.cachedSamples,
            bluePoints: input.package.bluePoints,
            redPoints: input.package.redPoints,
            brush: brush
        )
    }

    func previewComparisonBrush(kind: ModelKind) -> ManualRegionPreview? {
        guard let input = modelInput(for: kind), let brush = input.comparisonBrush else { return nil }
        return CropBrushEngine.makeManualRegionPreview(
            samples: input.package.cachedSamples,
            bluePoints: input.package.bluePoints,
            redPoints: input.package.redPoints,
            brush: brush
        )
    }

    func applyCropBrushAsROI(kind: ModelKind, reason: String = "Crop Brushを適用") async -> ROIReinspectDelta? {
        guard let input = modelInput(for: kind),
              let brush = input.cropBrush else { return nil }
        let selected = CropBrushEngine.selectedSamples(from: input.package.cachedSamples, brush: brush)
        let autoROI = CropBrushEngine.autoROI(from: selected, marginMeters: brush.autoROIMarginMeters)
        setROI(kind: kind, roi: autoROI)
        return await reinspectModel(kind: kind, reason: reason)
    }


    /// ROI値だけを更新する。再解析は呼び出し側で明示的に実行する。
    func setROI(kind: ModelKind, roi: SpatialBounds3D?) {
        guard var input = modelInput(for: kind) else { return }
        input.roi = roi
        setModelInput(input, for: kind)
    }

    /// ROI変更時はこちらを使ってUSDZ全体を再inspectする。
    /// `reextractMasks` は cachedSamples のしきい値再分類専用であり、
    /// ROIで三角形を除外し直す責務は持たせない。
    func reinspectModel(kind: ModelKind, reason: String = "ROIを反映") async -> ROIReinspectDelta? {
        guard var input = modelInput(for: kind) else { return nil }

        isBusy = true
        errorMessage = nil
        exportedCSVURL = nil
        analysisResult = nil
        overlayScene = nil
        statusMessage = "\(kind.rawValue) \(reason)して再解析中..."

        do {
            let config = self.config
            let fileURL = input.fileURL
            let roi = input.roi
            let previousPackage = input.package
            let package = try await Task.detached(priority: .userInitiated) {
                try USDZLoader.inspect(url: fileURL, config: config, roi: roi)
            }.value
            input.package = package
            setModelInput(input, for: kind)
            let delta = ROIReinspectDelta(before: previousPackage, after: package)
            statusMessage = "\(makeImportSummary(kind: kind, package: package)) | \(delta.compactText)"
            isBusy = false
            return delta
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "\(kind.rawValue) の再解析に失敗しました。"
        }

        isBusy = false
        return nil
    }

    func runComparison() async {
        guard let newInput, let usedInput else {
            errorMessage = "新品と走行品の両方を先に読み込んでください。"
            return
        }

        guard canCompare else {
            errorMessage = "比較には青/赤ともに最低 \(config.minimumMaskPoints) 点が必要です。まずデバッグしきい値を調整してください。"
            return
        }

        isBusy = true
        errorMessage = nil
        exportedCSVURL = nil
        statusMessage = "青領域で位置合わせ中..."

        do {
            let config = self.config
            let (newPackage, usedPackage, manualSummary) = try makeEffectivePackagesForComparison(
                newInput: newInput,
                usedInput: usedInput,
                minimumMaskPoints: config.minimumMaskPoints
            )
            let newURL = newInput.fileURL
            let usedURL = usedInput.fileURL
            statusMessage = "青領域で位置合わせ中... \(manualSummary)"

            let result = try await Task.detached(priority: .userInitiated) {
                try AnalysisCore.compare(newModel: newPackage,
                                         usedModel: usedPackage,
                                         config: config)
            }.value

            analysisResult = result
            overlayScene = try SceneOverlayBuilder.makeOverlayScene(newURL: newURL,
                                                                   usedURL: usedURL,
                                                                   usedToNew: result.usedToNew)
            statusMessage = "比較完了: 青RMS \(result.alignmentRMSMM.mmText)、推定肩摩耗 \(result.estimatedShoulderWearMM.mmText)"
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "比較に失敗しました。"
        }

        isBusy = false
    }

    private func makeEffectivePackagesForComparison(newInput: ModelInput,
                                                    usedInput: ModelInput,
                                                    minimumMaskPoints: Int) throws -> (LoadedModelPackage, LoadedModelPackage, String) {
        // MVP方針: 既存パイプラインを崩さず、比較直前に blue/red 点群へ空間ゲートを重ねる。
        // AnalysisCore.compare(...) には「既に整形済みの package」を渡すだけに留める。
        let hasNewAlignment = hasActiveManualRegion(newInput.alignmentBrush)
        let hasUsedAlignment = hasActiveManualRegion(usedInput.alignmentBrush)
        let hasNewComparison = hasActiveManualRegion(newInput.comparisonBrush)
        let hasUsedComparison = hasActiveManualRegion(usedInput.comparisonBrush)

        guard hasNewAlignment == hasUsedAlignment else {
            throw PoCError.profileFailed("Alignment Region は新品/走行品の両方に設定してください（片側のみは不可）。")
        }
        guard hasNewComparison == hasUsedComparison else {
            throw PoCError.profileFailed("Comparison Region は新品/走行品の両方に設定してください（片側のみは不可）。")
        }

        var effectiveNew = newInput.package
        var effectiveUsed = usedInput.package
        var summaryParts: [String] = []

        if hasNewAlignment,
           let newBrush = newInput.alignmentBrush,
           let usedBrush = usedInput.alignmentBrush {
            let newSelected = CropBrushEngine.selectedSamples(from: newInput.package.cachedSamples, brush: newBrush)
            let usedSelected = CropBrushEngine.selectedSamples(from: usedInput.package.cachedSamples, brush: usedBrush)
            let gatedNewBlue = CropBrushEngine.gateMaskPoints(newInput.package.bluePoints, selectedSamples: newSelected)
            let gatedUsedBlue = CropBrushEngine.gateMaskPoints(usedInput.package.bluePoints, selectedSamples: usedSelected)
            guard gatedNewBlue.count >= minimumMaskPoints, gatedUsedBlue.count >= minimumMaskPoints else {
                throw PoCError.alignmentFailed("Alignment Region適用後の青点が不足しています。新品 \(gatedNewBlue.count) / 走行品 \(gatedUsedBlue.count)（必要: \(minimumMaskPoints)）")
            }
            effectiveNew = effectiveNew.replacing(bluePoints: gatedNewBlue)
            effectiveUsed = effectiveUsed.replacing(bluePoints: gatedUsedBlue)
            summaryParts.append("Align sel \(newSelected.count)/\(usedSelected.count), blue \(gatedNewBlue.count)/\(gatedUsedBlue.count)")
        } else {
            summaryParts.append("Align auto blue \(newInput.package.bluePoints.count)/\(usedInput.package.bluePoints.count)")
        }

        if hasNewComparison,
           let newBrush = newInput.comparisonBrush,
           let usedBrush = usedInput.comparisonBrush {
            let newSelected = CropBrushEngine.selectedSamples(from: newInput.package.cachedSamples, brush: newBrush)
            let usedSelected = CropBrushEngine.selectedSamples(from: usedInput.package.cachedSamples, brush: usedBrush)
            let gatedNewRed = CropBrushEngine.gateMaskPoints(newInput.package.redPoints, selectedSamples: newSelected)
            let gatedUsedRed = CropBrushEngine.gateMaskPoints(usedInput.package.redPoints, selectedSamples: usedSelected)
            guard gatedNewRed.count >= minimumMaskPoints, gatedUsedRed.count >= minimumMaskPoints else {
                throw PoCError.profileFailed("Comparison Region適用後の赤点が不足しています。新品 \(gatedNewRed.count) / 走行品 \(gatedUsedRed.count)（必要: \(minimumMaskPoints)）")
            }
            effectiveNew = effectiveNew.replacing(redPoints: gatedNewRed)
            effectiveUsed = effectiveUsed.replacing(redPoints: gatedUsedRed)
            summaryParts.append("Comp sel \(newSelected.count)/\(usedSelected.count), red \(gatedNewRed.count)/\(gatedUsedRed.count)")
        } else {
            summaryParts.append("Comp auto red \(newInput.package.redPoints.count)/\(usedInput.package.redPoints.count)")
        }

        return (effectiveNew, effectiveUsed, summaryParts.joined(separator: " | "))
    }

    private func hasActiveManualRegion(_ brush: ManualRegionBrushState?) -> Bool {
        guard let brush else { return false }
        return brush.isEnabled && !brush.stamps.isEmpty
    }

    func exportCSV() {
        guard let analysisResult else {
            errorMessage = "比較結果がまだありません。"
            return
        }

        do {
            exportedCSVURL = try CSVExporter.export(
                result: analysisResult,
                newName: newInput?.package.displayName ?? "new",
                usedName: usedInput?.package.displayName ?? "used"
            )
            statusMessage = "CSVを書き出しました。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reset() {
        newInput = nil
        usedInput = nil
        analysisResult = nil
        overlayScene = nil
        exportedCSVURL = nil
        errorMessage = nil
        statusMessage = "新品と走行品のUSDZを読み込んでください。"
    }

    private func makeImportSummary(kind: ModelKind, package: LoadedModelPackage) -> String {
        var line = "\(kind.rawValue) 読込完了: blue \(package.bluePoints.count) / red \(package.redPoints.count), rawBlue \(package.rawBlueCount), rawRed \(package.rawRedCount), samples \(package.totalSamples)"
        if !package.warnings.isEmpty {
            line += "（警告 \(package.warnings.count) 件）"
        }
        return line
    }

    private func modelInput(for kind: ModelKind) -> ModelInput? {
        switch kind {
        case .new:
            return newInput
        case .used:
            return usedInput
        }
    }

    private func setModelInput(_ input: ModelInput, for kind: ModelKind) {
        switch kind {
        case .new:
            newInput = input
        case .used:
            usedInput = input
        }
    }
}
