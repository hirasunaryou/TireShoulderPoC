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

struct CropBrushPreview: Sendable {
    let selectedSampleCount: Int
    let autoROI: SpatialBounds3D?
    let selectedPoints: [Point3]
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

            let input = ModelInput(kind: kind, fileURL: localURL, roi: nil, cropBrush: nil, package: package)

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

    func previewCropBrushSelection(kind: ModelKind) -> CropBrushPreview? {
        guard let input = modelInput(for: kind), let brush = input.cropBrush else { return nil }
        let selected = USDZLoader.selectedSamples(from: input.package.cachedSamples, brush: brush)
        let autoROI = USDZLoader.autoROI(from: selected, marginMeters: brush.autoROIMarginMeters)
        return CropBrushPreview(
            selectedSampleCount: selected.count,
            autoROI: autoROI,
            selectedPoints: selected.map(\.worldPosition)
        )
    }

    func applyCropBrushAsROI(kind: ModelKind, reason: String = "Crop Brushを適用") async -> ROIReinspectDelta? {
        guard let input = modelInput(for: kind),
              let brush = input.cropBrush else { return nil }
        let selected = USDZLoader.selectedSamples(from: input.package.cachedSamples, brush: brush)
        let autoROI = USDZLoader.autoROI(from: selected, marginMeters: brush.autoROIMarginMeters)
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
            let newPackage = newInput.package
            let usedPackage = usedInput.package
            let newURL = newInput.fileURL
            let usedURL = usedInput.fileURL

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
