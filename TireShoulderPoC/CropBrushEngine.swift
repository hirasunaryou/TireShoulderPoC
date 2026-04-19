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
