import Foundation
import simd

enum CropBrushEngine {
    /// スタンプの add / erase を順序どおり適用し、最終的に選択中の sample を返す。
    /// 以前は「全stamp × 全sample」の総当たりだったため、塗るほど重くなっていた。
    /// Spatial index を使って近傍候補だけを見るようにして、描画時の引っかかりを減らす。
    static func selectedSamples(from samples: [CachedCentroidSample], brush: CropBrushState) -> [CachedCentroidSample] {
        guard !samples.isEmpty, !brush.stamps.isEmpty else { return [] }

        let index = SampleSpatialIndex(samples: samples, cellSize: optimalCellSize(for: brush.stamps))
        var selectedIndices = Set<Int>()
        selectedIndices.reserveCapacity(min(samples.count, brush.stamps.count * 32))

        for stamp in brush.stamps {
            let radiusSquared = stamp.radiusMeters * stamp.radiusMeters
            let candidateIndices = index.candidateIndices(around: stamp.center.simd, radius: stamp.radiusMeters)
            for candidateIndex in candidateIndices {
                let sample = samples[candidateIndex]
                let distanceSquared = simd_length_squared(sample.worldPosition.simd - stamp.center.simd)
                guard distanceSquared <= radiusSquared else { continue }
                switch stamp.mode {
                case .add:
                    selectedIndices.insert(candidateIndex)
                case .erase:
                    selectedIndices.remove(candidateIndex)
                }
            }
        }

        return samples.enumerated().compactMap { index, sample in
            selectedIndices.contains(index) ? sample : nil
        }
    }

    static func selectedPoints(from samples: [CachedCentroidSample]) -> [Point3] {
        samples.map(\.worldPosition)
    }

    static func nearestSamplePosition(to point: Point3,
                                      in samples: [CachedCentroidSample],
                                      within radiusMeters: Float) -> Point3? {
        guard !samples.isEmpty else { return nil }

        let safeRadius = max(radiusMeters, 0.00075)
        let index = SampleSpatialIndex(samples: samples, cellSize: max(safeRadius * 0.5, 0.00075))
        let radiusSquared = safeRadius * safeRadius

        var bestPoint: Point3?
        var bestDistanceSquared = Float.greatestFiniteMagnitude

        for candidateIndex in index.candidateIndices(around: point.simd, radius: safeRadius) {
            let sample = samples[candidateIndex]
            let distanceSquared = simd_length_squared(sample.worldPosition.simd - point.simd)
            guard distanceSquared <= radiusSquared else { continue }
            if distanceSquared < bestDistanceSquared {
                bestDistanceSquared = distanceSquared
                bestPoint = sample.worldPosition
            }
        }

        return bestPoint
    }

    static func autoROI(from selected: [CachedCentroidSample], marginMeters: Float) -> SpatialBounds3D? {
        guard !selected.isEmpty else { return nil }
        guard let bounds = SpatialBounds3D(points: selected.map { $0.worldPosition.simd }) else { return nil }
        let margin = max(0, marginMeters)
        return SpatialBounds3D(
            min: Point3(
                x: bounds.min.x - margin,
                y: bounds.min.y - margin,
                z: bounds.min.z - margin
            ),
            max: Point3(
                x: bounds.max.x + margin,
                y: bounds.max.y + margin,
                z: bounds.max.z + margin
            )
        )
    }

    static func makePreview(samples: [CachedCentroidSample], brush: CropBrushState) -> CropBrushPreview {
        let selected = selectedSamples(from: samples, brush: brush)
        return CropBrushPreview(
            selectedSampleCount: selected.count,
            selectedPoints: selectedPoints(from: selected),
            autoROI: autoROI(from: selected, marginMeters: brush.autoROIMarginMeters)
        )
    }

    static func selectedSamples(from samples: [CachedCentroidSample], manualBrush: ManualRegionBrushState) -> [CachedCentroidSample] {
        guard manualBrush.isEnabled else { return [] }
        let cropStyleBrush = CropBrushState(
            stamps: manualBrush.stamps,
            radiusMeters: manualBrush.radiusMeters,
            autoROIMarginMeters: 0
        )
        return selectedSamples(from: samples, brush: cropStyleBrush)
    }

    static func selectedPointPositions(from samples: [CachedCentroidSample], manualBrush: ManualRegionBrushState) -> [Point3] {
        selectedSamples(from: samples, manualBrush: manualBrush).map(\.worldPosition)
    }

    /// Manual Region は auto mask のゲートではなく、ユーザーが塗った sampled surface を
    /// そのまま比較用点群として使う。
    static func effectiveManualRegionPoints(samples: [CachedCentroidSample],
                                            manualBrush: ManualRegionBrushState) -> [Point3] {
        selectedPointPositions(from: samples, manualBrush: manualBrush)
    }

    static func makeManualRegionPreview(samples: [CachedCentroidSample],
                                        manualBrush: ManualRegionBrushState,
                                        role: ManualRegionRole) -> ManualRegionPreview {
        let selectedPositions = effectiveManualRegionPoints(samples: samples, manualBrush: manualBrush)
        return ManualRegionPreview(
            selectedPoints: selectedPositions,
            selectedCount: selectedPositions.count,
            effectivePointCount: selectedPositions.count,
            role: role
        )
    }

    static func gate(points: [Point3], selectedPositions: [Point3], epsilonMeters: Float = 0.0015) -> [Point3] {
        guard !points.isEmpty, !selectedPositions.isEmpty else { return [] }
        let epsilonSq = epsilonMeters * epsilonMeters
        return points.filter { point in
            selectedPositions.contains { selected in
                simd_length_squared(point.simd - selected.simd) <= epsilonSq
            }
        }
    }

    private static func optimalCellSize(for stamps: [BrushStamp3D]) -> Float {
        let minimumRadius = stamps
            .map(\.radiusMeters)
            .filter { $0 > 0 }
            .min() ?? CropBrushState.default.radiusMeters
        return max(minimumRadius * 0.75, 0.00075)
    }
}

private struct SampleSpatialIndex {
    private struct CellKey: Hashable {
        let x: Int
        let y: Int
        let z: Int

        init(point: SIMD3<Float>, cellSize: Float) {
            let safeSize = max(cellSize, 0.000_001)
            self.x = Int(floor(point.x / safeSize))
            self.y = Int(floor(point.y / safeSize))
            self.z = Int(floor(point.z / safeSize))
        }

        init(x: Int, y: Int, z: Int) {
            self.x = x
            self.y = y
            self.z = z
        }
    }

    let samples: [CachedCentroidSample]
    let cellSize: Float
    private let buckets: [CellKey: [Int]]

    init(samples: [CachedCentroidSample], cellSize: Float) {
        self.samples = samples
        self.cellSize = max(cellSize, 0.00075)

        var buckets: [CellKey: [Int]] = [:]
        buckets.reserveCapacity(samples.count)

        for (index, sample) in samples.enumerated() {
            let key = CellKey(point: sample.worldPosition.simd, cellSize: self.cellSize)
            buckets[key, default: []].append(index)
        }

        self.buckets = buckets
    }

    func candidateIndices(around center: SIMD3<Float>, radius: Float) -> [Int] {
        let safeRadius = max(radius, cellSize)
        let range = max(1, Int(ceil(safeRadius / cellSize)))
        let centerKey = CellKey(point: center, cellSize: cellSize)

        var result: [Int] = []
        result.reserveCapacity((range * 2 + 1) * (range * 2 + 1) * 8)

        for x in (centerKey.x - range)...(centerKey.x + range) {
            for y in (centerKey.y - range)...(centerKey.y + range) {
                for z in (centerKey.z - range)...(centerKey.z + range) {
                    if let bucket = buckets[CellKey(x: x, y: y, z: z)] {
                        result.append(contentsOf: bucket)
                    }
                }
            }
        }

        return result
    }
}
