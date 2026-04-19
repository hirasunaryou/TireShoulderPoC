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

enum InspectorRenderMode: String, CaseIterable, Identifiable {
    case texturedMesh = "Textured Mesh"
    case sampledRGB = "Sampled RGB"
    case maskLocator = "Mask Locator"

    var id: String { rawValue }
}

enum InspectorFocusMode: String, CaseIterable, Identifiable {
    case model = "Model"
    case roi = "ROI"
    case colorRich = "Color-Rich"
    case blue = "Blue"
    case red = "Red"

    var id: String { rawValue }
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

/// 3D空間のAABB(軸平行境界ボックス)。
/// ROI指定や、読み込んだモデル全体のsource bounds保存に使う。
struct SpatialBounds3D: Hashable, Sendable {
    var min: Point3
    var max: Point3

    init(min: Point3, max: Point3) {
        self.min = Point3(
            x: Swift.min(min.x, max.x),
            y: Swift.min(min.y, max.y),
            z: Swift.min(min.z, max.z)
        )
        self.max = Point3(
            x: Swift.max(min.x, max.x),
            y: Swift.max(min.y, max.y),
            z: Swift.max(min.z, max.z)
        )
    }

    init?(points: [SIMD3<Float>]) {
        guard let first = points.first else { return nil }

        var minX = first.x
        var minY = first.y
        var minZ = first.z
        var maxX = first.x
        var maxY = first.y
        var maxZ = first.z

        for point in points.dropFirst() {
            minX = Swift.min(minX, point.x)
            minY = Swift.min(minY, point.y)
            minZ = Swift.min(minZ, point.z)
            maxX = Swift.max(maxX, point.x)
            maxY = Swift.max(maxY, point.y)
            maxZ = Swift.max(maxZ, point.z)
        }

        self.init(
            min: Point3(x: minX, y: minY, z: minZ),
            max: Point3(x: maxX, y: maxY, z: maxZ)
        )
    }

    func intersects(_ other: SpatialBounds3D) -> Bool {
        !(max.x < other.min.x || min.x > other.max.x ||
          max.y < other.min.y || min.y > other.max.y ||
          max.z < other.min.z || min.z > other.max.z)
    }
}

struct HSVColor: Sendable {
    var hue: Float
    var saturation: Float
    var value: Float
}

struct CachedCentroidSample: Identifiable, Sendable {
    let id = UUID()
    let worldPosition: Point3
    let rgb: SIMD3<Float>
    let hsv: HSVColor
}

enum BrushPaintMode: String, CaseIterable, Hashable, Sendable {
    case add
    case erase
}

struct BrushStamp3D: Identifiable, Hashable, Sendable {
    let id: UUID
    let center: Point3
    let radiusMeters: Float
    let mode: BrushPaintMode

    init(id: UUID = UUID(), center: Point3, radiusMeters: Float, mode: BrushPaintMode) {
        self.id = id
        self.center = center
        self.radiusMeters = radiusMeters
        self.mode = mode
    }
}

struct CropBrushState: Hashable, Sendable {
    var stamps: [BrushStamp3D]
    var radiusMeters: Float
    var autoROIMarginMeters: Float

    static let `default` = CropBrushState(stamps: [], radiusMeters: 0.006, autoROIMarginMeters: 0.004)
}

/// 将来の拡張（①位置合わせ領域 / ②比較領域）を見据えたブラシ用途。
/// まずは crop だけをUIに出し、内部構造は用途追加に耐える形にしておく。
enum SurfaceMaskPurpose: String, CaseIterable, Hashable, Sendable {
    case crop
    case alignment
    case comparison
}

/// 用途ごとのブラシ状態コンテナ。
/// 将来 alignment/comparison 用ブラシを追加する際はここに保存するだけで、
/// `ModelInput` の構造を崩さずに拡張できる。
struct SurfaceMaskSet: Hashable, Sendable {
    var crop: CropBrushState?
    var alignment: CropBrushState?
    var comparison: CropBrushState?

    subscript(_ purpose: SurfaceMaskPurpose) -> CropBrushState? {
        get {
            switch purpose {
            case .crop: return crop
            case .alignment: return alignment
            case .comparison: return comparison
            }
        }
        set {
            switch purpose {
            case .crop: crop = newValue
            case .alignment: alignment = newValue
            case .comparison: comparison = newValue
            }
        }
    }
}

struct MaterialInspectionRecord: Identifiable, Sendable {
    let id = UUID()
    let nodeName: String
    let geometryName: String
    let materialIndex: Int
    let hasUV: Bool
    let hasVertexColor: Bool
    let triangleCount: Int
    let sampledTriangleCount: Int
    let textureSourceSummary: String
    let diffuseType: String?
    let emissionType: String?
    let multiplyType: String?
    let selfIlluminationType: String?
    let transparentType: String?
    let metalnessType: String?
    let roughnessType: String?
}

struct ModelIOMaterialInspectionRecord: Identifiable, Sendable {
    let id = UUID()
    let meshName: String
    let submeshIndex: Int
    let hasMaterial: Bool
    let hasBaseColor: Bool
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
    let geometryNodeCount: Int
    let totalSamples: Int
    let rawBlueCount: Int
    let rawRedCount: Int
    let skippedNoUVTriangles: Int
    let materialRecords: [MaterialInspectionRecord]
    let modelIOMaterialRecords: [ModelIOMaterialInspectionRecord]
    let cachedSamples: [CachedCentroidSample]
    /// ブラシやROI後に「現在有効」とみなすサンプル。
    /// 表示・再分類はこの配列を基準に行う。
    let activeSamples: [CachedCentroidSample]
    let sourceBounds: SpatialBounds3D
    var sampledPoints: [Point3] { activeSamples.map(\.worldPosition) }
    var colorRichPoints: [Point3] { activeSamples.filter { $0.hsv.saturation >= 0.05 }.map(\.worldPosition) }
    let meanR: Float
    let meanG: Float
    let meanB: Float
    let meanHue: Float
    let meanSaturation: Float
    let meanValue: Float
    let minSaturationObserved: Float
    let maxSaturationObserved: Float
    let minValueObserved: Float
    let maxValueObserved: Float
    let warnings: [String]
}

struct ModelInput {
    let kind: ModelKind
    let fileURL: URL
    var roi: SpatialBounds3D?
    var surfaceMasks: SurfaceMaskSet = SurfaceMaskSet()
    var package: LoadedModelPackage
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
    var blueHueRange: ClosedRange<Float> = 170 ... 270
    var redHueLowMax: Float = 30
    var redHueHighMin: Float = 330

    var minSaturation: Float = 0.08
    var minValue: Float = 0.05

    var maskVoxelSizeMeters: Float = 0.0015
    var profileVoxelSizeMeters: Float = 0.0015

    var minimumMaskPoints: Int = 20
    var icpSampleLimit: Int = 1_200
    var icpMaxIterations: Int = 18
    var icpTrimFraction: Float = 0.80
    var icpConvergenceEpsilonMeters: Float = 0.000_02

    var profileBinCount: Int = 120
    var profileSmoothingWindow: Int = 2

    var redHueRanges: [ClosedRange<Float>] {
        [0 ... redHueLowMax, redHueHighMin ... 360]
    }
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
