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
}
