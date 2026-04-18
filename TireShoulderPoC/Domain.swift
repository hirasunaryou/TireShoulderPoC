import Foundation
import simd

enum ModelKind: String, CaseIterable, Identifiable {
    case new = "新品"
    case used = "走行品"

    var id: String { rawValue }

    var englishName: String {
        switch self {
        case .new: return "new"
        case .used: return "used"
        }
    }
}

struct Point3: Hashable, Sendable {
    var x: Float
    var y: Float
    var z: Float

    init(x: Float, y: Float, z: Float) {
        self.x = x
        self.y = y
        self.z = z
    }

    init(_ value: SIMD3<Float>) {
        self.x = value.x
        self.y = value.y
        self.z = value.z
    }

    var simd: SIMD3<Float> {
        SIMD3<Float>(x, y, z)
    }
}

struct Transform4x4: Sendable {
    var values: [Float]

    init(_ matrix: simd_float4x4 = matrix_identity_float4x4) {
        self.values = [
            matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z, matrix.columns.0.w,
            matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z, matrix.columns.1.w,
            matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z, matrix.columns.2.w,
            matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z, matrix.columns.3.w
        ]
    }

    var simd: simd_float4x4 {
        guard values.count == 16 else { return matrix_identity_float4x4 }
        return simd_float4x4(columns: (
            SIMD4<Float>(values[0], values[1], values[2], values[3]),
            SIMD4<Float>(values[4], values[5], values[6], values[7]),
            SIMD4<Float>(values[8], values[9], values[10], values[11]),
            SIMD4<Float>(values[12], values[13], values[14], values[15])
        ))
    }
}

struct LoadedModelPackage: Sendable {
    let displayName: String
    let bluePoints: [Point3]
    let redPoints: [Point3]
    let totalSamples: Int
}

struct ModelInput {
    let kind: ModelKind
    let fileURL: URL
    let package: LoadedModelPackage
}

struct ProfileSample: Identifiable, Sendable {
    let id = UUID()
    let xMM: Double
    let newYMM: Double
    let usedYMM: Double
    let deltaMM: Double
}

struct ComparisonResult: Sendable {
    let usedToNew: Transform4x4
    let initialAlignmentRMSMM: Float
    let alignmentRMSMM: Float
    let newBlueCount: Int
    let usedBlueCount: Int
    let newRedCount: Int
    let usedRedCount: Int
    let meanAbsDeltaMM: Float
    let p95AbsDeltaMM: Float
    let maxAbsDeltaMM: Float
    let estimatedShoulderWearMM: Float
    let overlapLengthMM: Float
    let samples: [ProfileSample]
}

struct AnalysisConfig: Sendable {
    var blueHueRange: ClosedRange<Float> = 200 ... 250
    var redHueRanges: [ClosedRange<Float>] = [0 ... 18, 345 ... 360]
    var minSaturation: Float = 0.35
    var minValue: Float = 0.15

    var maskVoxelSizeMeters: Float = 0.0015
    var profileVoxelSizeMeters: Float = 0.0015

    var minimumMaskPoints: Int = 120
    var icpSampleLimit: Int = 1_200
    var icpMaxIterations: Int = 18
    var icpTrimFraction: Float = 0.80
    var icpConvergenceEpsilonMeters: Float = 0.000_02

    var profileBinCount: Int = 120
    var profileSmoothingWindow: Int = 2
}

enum PoCError: LocalizedError {
    case fileImportFailed(String)
    case sceneLoadFailed(String)
    case geometryMissing
    case maskExtractionFailed(String)
    case alignmentFailed(String)
    case profileFailed(String)
    case csvExportFailed(String)

    var errorDescription: String? {
        switch self {
        case .fileImportFailed(let message):
            return "ファイル取込に失敗しました: \(message)"
        case .sceneLoadFailed(let message):
            return "USDZの読み込みに失敗しました: \(message)"
        case .geometryMissing:
            return "メッシュ形状が見つかりませんでした。USDZの中身を確認してください。"
        case .maskExtractionFailed(let message):
            return "青/赤マスクの抽出に失敗しました: \(message)"
        case .alignmentFailed(let message):
            return "青領域の位置合わせに失敗しました: \(message)"
        case .profileFailed(let message):
            return "赤領域のプロファイル比較に失敗しました: \(message)"
        case .csvExportFailed(let message):
            return "CSV出力に失敗しました: \(message)"
        }
    }
}
