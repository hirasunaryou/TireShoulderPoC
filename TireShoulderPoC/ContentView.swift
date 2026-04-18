import SwiftUI
import Charts
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var activeImportKind: ModelKind?
    @State private var isImporterPresented = false

    private var usdzType: UTType {
        UTType(filenameExtension: "usdz") ?? .data
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerSection
                    loadSection
                    actionSection
                    statusSection
                    debugInspectorSection

                    if let overlayScene = appModel.overlayScene {
                        GroupBox("3D重ね合わせ") {
                            SceneKitOverlayView(scene: overlayScene)
                                .frame(height: 320)

                            Text("操作: 1本指で回転 / 2本指でパン / ピンチでズーム")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(.top, 6)
                        }
                    }

                    if let result = appModel.analysisResult {
                        metricsSection(result)
                        profileChartSection(result)
                        exportSection
                    }

                    notesSection
                }
                .padding()
            }
            .navigationTitle("Tire Shoulder PoC")
            .fileImporter(
                isPresented: $isImporterPresented,
                allowedContentTypes: [usdzType],
                allowsMultipleSelection: false
            ) { result in
                guard let selectedKind = activeImportKind else {
                    appModel.errorMessage = "読込種別が失われました。もう一度選択してください。"
                    return
                }

                defer {
                    activeImportKind = nil
                    isImporterPresented = false
                }

                switch result {
                case .success(let urls):
                    guard let url = urls.first else {
                        appModel.errorMessage = "ファイルが選択されませんでした。"
                        return
                    }

                    appModel.statusMessage = "\(selectedKind.rawValue) USDZを読込中..."
                    Task {
                        await appModel.importModel(kind: selectedKind, from: url)
                    }

                case .failure(let error):
                    appModel.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private var headerSection: some View {
        GroupBox("目的") {
            VStack(alignment: .leading, spacing: 8) {
                Text("青テープで新品/走行品の位置合わせを行い、赤テープ帯の断面プロファイルを比較します。")
                Text("この版は“まず現場で回す”ことを優先したPoCです。ヒートマップより先に、位置合わせRMSと赤帯プロファイル差分のCSVを出します。")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }
        }
    }

    private var loadSection: some View {
        GroupBox("USDZ読込") {
            VStack(spacing: 12) {
                LoadCard(
                    title: "新品モデル",
                    subtitle: appModel.newInput?.package.displayName ?? "未読込",
                    blueCount: appModel.newInput?.package.bluePoints.count,
                    redCount: appModel.newInput?.package.redPoints.count,
                    warningCount: appModel.newInput?.package.warnings.count,
                    actionTitle: "新品USDZを選ぶ"
                ) {
                    activeImportKind = .new
                    isImporterPresented = true
                }

                LoadCard(
                    title: "走行品モデル",
                    subtitle: appModel.usedInput?.package.displayName ?? "未読込",
                    blueCount: appModel.usedInput?.package.bluePoints.count,
                    redCount: appModel.usedInput?.package.redPoints.count,
                    warningCount: appModel.usedInput?.package.warnings.count,
                    actionTitle: "走行品USDZを選ぶ"
                ) {
                    activeImportKind = .used
                    isImporterPresented = true
                }
            }
        }
    }

    private var actionSection: some View {
        GroupBox("操作") {
            HStack(spacing: 12) {
                Button {
                    Task {
                        await appModel.runComparison()
                    }
                } label: {
                    Label("比較を実行", systemImage: "arrow.triangle.merge")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(appModel.isBusy || !appModel.canRunComparison)

                Button("リセット", role: .destructive) {
                    appModel.reset()
                }
                .buttonStyle(.bordered)
                .disabled(appModel.isBusy)
            }

            if appModel.isBusy {
                ProgressView()
                    .padding(.top, 8)
            }
        }
    }

    private var statusSection: some View {
        Group {
            if let errorMessage = appModel.errorMessage {
                GroupBox("エラー") {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }

            GroupBox("状態") {
                Text(appModel.statusMessage)
                    .font(.subheadline)
            }
        }
    }

    private var debugInspectorSection: some View {
        Group {
            if let newInput = appModel.newInput {
                DebugInspectorView(
                    title: "Debug Inspector - 新品",
                    input: newInput,
                    scene: appModel.debugSceneByKind[.new],
                    config: $appModel.config
                ) {
                    appModel.reextractMasks(kind: .new)
                }
            }

            if let usedInput = appModel.usedInput {
                DebugInspectorView(
                    title: "Debug Inspector - 走行品",
                    input: usedInput,
                    scene: appModel.debugSceneByKind[.used],
                    config: $appModel.config
                ) {
                    appModel.reextractMasks(kind: .used)
                }
            }
        }
    }

    private func metricsSection(_ result: ComparisonResult) -> some View {
        GroupBox("比較結果") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                MetricCell(title: "青RMS", value: result.alignmentRMSMM.mmText)
                MetricCell(title: "初期RMS", value: result.initialAlignmentRMSMM.mmText)
                MetricCell(title: "平均|差|", value: result.meanAbsDeltaMM.mmText)
                MetricCell(title: "P95 |差|", value: result.p95AbsDeltaMM.mmText)
                MetricCell(title: "最大|差|", value: result.maxAbsDeltaMM.mmText)
                MetricCell(title: "推定肩摩耗", value: result.estimatedShoulderWearMM.mmText)
                MetricCell(title: "重複長さ", value: result.overlapLengthMM.mmText)
                MetricCell(title: "赤サンプル", value: "\(result.newRedCount) / \(result.usedRedCount)")
            }
            .padding(.top, 4)

            Text("差分の符号は `新品 - 走行品` です。PoCでは、差が大きい端が正になる向きに自動で揃えています。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
        }
    }

    private func profileChartSection(_ result: ComparisonResult) -> some View {
        GroupBox("赤テープ帯プロファイル") {
            Chart {
                ForEach(result.samples) { sample in
                    LineMark(
                        x: .value("x [mm]", sample.xMM),
                        y: .value("profile [mm]", sample.newYMM)
                    )
                    .foregroundStyle(by: .value("Series", "新品"))
                }

                ForEach(result.samples) { sample in
                    LineMark(
                        x: .value("x [mm]", sample.xMM),
                        y: .value("profile [mm]", sample.usedYMM)
                    )
                    .foregroundStyle(by: .value("Series", "走行品"))
                }
            }
            .frame(height: 260)

            Chart {
                ForEach(result.samples) { sample in
                    LineMark(
                        x: .value("x [mm]", sample.xMM),
                        y: .value("delta [mm]", sample.deltaMM)
                    )
                }
            }
            .frame(height: 180)
            .padding(.top, 8)

            Text("上段: 新品/走行品の2本線。下段: `新品 - 走行品` の差分線。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        }
    }

    private var exportSection: some View {
        GroupBox("CSV出力") {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    appModel.exportCSV()
                } label: {
                    Label("CSVを書き出す", systemImage: "tablecells")
                }
                .buttonStyle(.bordered)

                if let exportedCSVURL = appModel.exportedCSVURL {
                    ShareLink(item: exportedCSVURL) {
                        Label("書き出したCSVを共有", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
    }

    private var notesSection: some View {
        GroupBox("現場での注意") {
            VStack(alignment: .leading, spacing: 8) {
                Text("1. 青テープは左右対称にせず、L字や切り欠き付きにする")
                Text("2. 青と赤はマットな高彩度テープを使う")
                Text("3. 新品/走行品で同じ内圧・同じ姿勢・同じ照明にそろえる")
                Text("4. まずは新品 vs 同じ新品 を繰り返してノイズ床を確認する")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }
}

private struct LoadCard: View {
    let title: String
    let subtitle: String
    let blueCount: Int?
    let redCount: Int?
    let warningCount: Int?
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Label("青 \(blueCount.map { String($0) } ?? "-")", systemImage: "square.fill")
                Label("赤 \(redCount.map { String($0) } ?? "-")", systemImage: "square.fill")
                Label("警告 \(warningCount.map { String($0) } ?? "0")", systemImage: "exclamationmark.triangle")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            Button(actionTitle, action: action)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct MetricCell: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
