import Foundation
import SceneKit
import SwiftUI

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
    @Published var debugSceneByKind: [ModelKind: SCNScene] = [:]

    @Published var config = AnalysisConfig()

    func importModel(kind: ModelKind, from pickedURL: URL) async {
        isBusy = true
        errorMessage = nil
        exportedCSVURL = nil
        analysisResult = nil
        overlayScene = nil
        debugSceneByKind = [:]
        statusMessage = "\(kind.rawValue) USDZを解析中..."

        do {
            let localURL = try LocalFileStore.importCopy(from: pickedURL, preferredName: pickedURL.lastPathComponent)
            let config = self.config

            let package = try await Task.detached(priority: .userInitiated) {
                try USDZLoader.inspect(url: localURL, config: config)
            }.value

            let input = ModelInput(kind: kind, fileURL: localURL, package: package)

            switch kind {
            case .new:
                newInput = input
            case .used:
                usedInput = input
            }

            do {
                debugSceneByKind[kind] = try SceneOverlayBuilder.makeInspectionScene(
                    modelURL: localURL,
                    bluePoints: package.bluePoints,
                    redPoints: package.redPoints
                )
            } catch {
                debugSceneByKind[kind] = nil
            }

            let warningText = package.warnings.isEmpty ? "" : " / 警告 \(package.warnings.count)件"
            statusMessage = "\(kind.rawValue) 読込完了: 青 \(package.bluePoints.count)点 / 赤 \(package.redPoints.count)点 / 総サンプル \(package.totalSamples)\(warningText)"
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "読み込みに失敗しました。"
        }

        isBusy = false
    }

    func runComparison() async {
        guard let newInput, let usedInput else {
            errorMessage = "新品と走行品の両方を先に読み込んでください。"
            return
        }
        guard canRunComparison else {
            errorMessage = "比較には新品/走行品ともに青赤マスク点が最低 \(config.minimumMaskPoints) 点必要です。"
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

    func reextractMasks(kind: ModelKind) {
        analysisResult = nil
        overlayScene = nil
        exportedCSVURL = nil

        let existingInput: ModelInput?
        switch kind {
        case .new:
            existingInput = newInput
        case .used:
            existingInput = usedInput
        }
        guard let existingInput else { return }

        let updatedPackage = USDZLoader.reextractMasks(from: existingInput.package, config: config)
        let updatedInput = ModelInput(kind: kind, fileURL: existingInput.fileURL, package: updatedPackage)

        do {
            let debugScene = try SceneOverlayBuilder.makeInspectionScene(
                modelURL: existingInput.fileURL,
                bluePoints: updatedPackage.bluePoints,
                redPoints: updatedPackage.redPoints
            )
            debugSceneByKind[kind] = debugScene
        } catch {
            errorMessage = error.localizedDescription
        }

        switch kind {
        case .new:
            newInput = updatedInput
        case .used:
            usedInput = updatedInput
        }

        statusMessage = "\(kind.rawValue) マスク再抽出: 青 \(updatedPackage.bluePoints.count) / 赤 \(updatedPackage.redPoints.count)"
    }

    var canRunComparison: Bool {
        guard let newInput, let usedInput else { return false }
        let minPoints = config.minimumMaskPoints
        return newInput.package.bluePoints.count >= minPoints &&
        newInput.package.redPoints.count >= minPoints &&
        usedInput.package.bluePoints.count >= minPoints &&
        usedInput.package.redPoints.count >= minPoints
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
        debugSceneByKind = [:]
        errorMessage = nil
        statusMessage = "新品と走行品のUSDZを読み込んでください。"
    }
}
