import Foundation
import simd

enum CropBrushEngine {
    /// スタンプの add / erase を順序どおり適用し、最終的に選択中の sample を返す。
    static func selectedSamples(from samples: [CachedCentroidSample], brush: CropBrushState) -> [CachedCentroidSample] {
        guard !samples.isEmpty, !brush.stamps.isEmpty else { return [] }

        var selectedIDs = Set<UUID>()
        for stamp in brush.stamps {
            let radiusSquared = stamp.radiusMeters * stamp.radiusMeters
            for sample in samples {
                let distanceSquared = simd_length_squared(sample.worldPosition.simd - stamp.center.simd)
                guard distanceSquared <= radiusSquared else { continue }
                switch stamp.mode {
                case .add:
                    selectedIDs.insert(sample.id)
                case .erase:
                    selectedIDs.remove(sample.id)
                }
            }
        }

        return samples.filter { selectedIDs.contains($0.id) }
    }

    static func selectedPoints(from samples: [CachedCentroidSample]) -> [Point3] {
        samples.map(\.worldPosition)
    }

    static func selectedSamples(from samples: [CachedCentroidSample], brush: ManualRegionBrushState) -> [CachedCentroidSample] {
        guard brush.isEnabled else { return [] }
        let cropLikeBrush = CropBrushState(stamps: brush.stamps, radiusMeters: brush.radiusMeters, autoROIMarginMeters: 0)
        return selectedSamples(from: samples, brush: cropLikeBrush)
    }

    static func gateMaskPoints(_ points: [Point3],
                               selectedSamples: [CachedCentroidSample],
                               epsilonMeters: Float = 0.0012) -> [Point3] {
        guard !points.isEmpty, !selectedSamples.isEmpty else { return [] }
        let grid = SpatialHashGrid(points: selectedSamples.map(\.worldPosition.simd), cellSize: max(epsilonMeters, 0.0001))
        return points.filter { grid.containsNearby($0.simd, epsilon: epsilonMeters) }
    }

    static func makeManualRegionPreview(samples: [CachedCentroidSample],
                                        bluePoints: [Point3],
                                        redPoints: [Point3],
                                        brush: ManualRegionBrushState) -> ManualRegionPreview {
        let selected = selectedSamples(from: samples, brush: brush)
        return ManualRegionPreview(
            selectedPoints: selectedPoints(from: selected),
            selectedCount: selected.count,
            gatedBlueCount: gateMaskPoints(bluePoints, selectedSamples: selected).count,
            gatedRedCount: gateMaskPoints(redPoints, selectedSamples: selected).count
        )
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
}

private struct GridKey: Hashable {
    let x: Int
    let y: Int
    let z: Int
}

private struct SpatialHashGrid {
    let cellSize: Float
    let table: [GridKey: [SIMD3<Float>]]

    init(points: [SIMD3<Float>], cellSize: Float) {
        self.cellSize = cellSize
        var table: [GridKey: [SIMD3<Float>]] = [:]
        table.reserveCapacity(points.count)
        for point in points {
            let key = Self.key(for: point, cellSize: cellSize)
            table[key, default: []].append(point)
        }
        self.table = table
    }

    func containsNearby(_ point: SIMD3<Float>, epsilon: Float) -> Bool {
        let base = Self.key(for: point, cellSize: cellSize)
        let threshold = epsilon * epsilon
        for dx in -1...1 {
            for dy in -1...1 {
                for dz in -1...1 {
                    let neighbor = GridKey(x: base.x + dx, y: base.y + dy, z: base.z + dz)
                    guard let candidates = table[neighbor] else { continue }
                    for candidate in candidates where simd_length_squared(candidate - point) <= threshold {
                        return true
                    }
                }
            }
        }
        return false
    }

    private static func key(for point: SIMD3<Float>, cellSize: Float) -> GridKey {
        GridKey(
            x: Int(floor(point.x / cellSize)),
            y: Int(floor(point.y / cellSize)),
            z: Int(floor(point.z / cellSize))
        )
    }
}
