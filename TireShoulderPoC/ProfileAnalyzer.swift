import Foundation
import simd

struct ProfileComputationResult {
    let samples: [ProfileSample]
    let meanAbsDeltaMM: Float
    let p95AbsDeltaMM: Float
    let maxAbsDeltaMM: Float
    let estimatedShoulderWearMM: Float
    let overlapLengthMM: Float
}

private struct ProjectedPoint {
    let x: Float
    let y: Float
    let z: Float
}

enum ProfileAnalyzer {
    static func compare(newPoints rawNewPoints: [SIMD3<Float>],
                        usedPointsAligned rawUsedPoints: [SIMD3<Float>],
                        config: AnalysisConfig) throws -> ProfileComputationResult {
        let newPoints = voxelDownsample(rawNewPoints, size: config.profileVoxelSizeMeters)
        let usedPoints = voxelDownsample(rawUsedPoints, size: config.profileVoxelSizeMeters)

        guard newPoints.count >= config.minimumMaskPoints else {
            throw PoCError.profileFailed("新品の赤点群が少なすぎます。\(newPoints.count) 点しかありません。")
        }
        guard usedPoints.count >= config.minimumMaskPoints else {
            throw PoCError.profileFailed("走行品の赤点群が少なすぎます。\(usedPoints.count) 点しかありません。")
        }

        let pcaResult = pca(of: newPoints)
        var projectedNew = project(points: newPoints, center: pcaResult.center, basis: pcaResult.basis)
        var projectedUsed = project(points: usedPoints, center: pcaResult.center, basis: pcaResult.basis)

        projectedNew = filterNearPlane(projectedNew)
        projectedUsed = filterNearPlane(projectedUsed)

        guard projectedNew.count >= config.minimumMaskPoints else {
            throw PoCError.profileFailed("新品の赤点群が平面投影後に不足しました。")
        }
        guard projectedUsed.count >= config.minimumMaskPoints else {
            throw PoCError.profileFailed("走行品の赤点群が平面投影後に不足しました。")
        }

        guard let xRange = overlappedXRange(new: projectedNew, used: projectedUsed), xRange.upperBound > xRange.lowerBound else {
            throw PoCError.profileFailed("赤リボンの共通区間が見つかりませんでした。")
        }

        let newCurve = interpolateMissingValues(
            binnedMedianCurve(points: projectedNew, xRange: xRange, bins: config.profileBinCount)
        )
        let usedCurve = interpolateMissingValues(
            binnedMedianCurve(points: projectedUsed, xRange: xRange, bins: config.profileBinCount)
        )

        var xValues: [Float] = []
        var newYValues: [Float] = []
        var usedYValues: [Float] = []

        for index in 0..<config.profileBinCount {
            let newCandidate: Float? = index < newCurve.count ? newCurve[index] : nil
            let usedCandidate: Float? = index < usedCurve.count ? usedCurve[index] : nil

            guard let newY = newCandidate,
                  let usedY = usedCandidate else {
                continue
            }

            let t = (Float(index) + 0.5) / Float(config.profileBinCount)
            let x = xRange.lowerBound + (xRange.upperBound - xRange.lowerBound) * t

            xValues.append(x)
            newYValues.append(newY)
            usedYValues.append(usedY)
        }

        guard xValues.count >= 12 else {
            throw PoCError.profileFailed("比較に使えるプロファイル点が不足しました。")
        }

        newYValues = movingAverage(newYValues, radius: config.profileSmoothingWindow)
        usedYValues = movingAverage(usedYValues, radius: config.profileSmoothingWindow)

        var deltas = zip(newYValues, usedYValues).map { pair in
            pair.0 - pair.1
        }

        let edgeWindow = max(3, deltas.count / 5)
        let leftAnchor = average(Array(deltas.prefix(edgeWindow)))
        let rightAnchor = average(Array(deltas.suffix(edgeWindow)))
        let dominantAnchor = abs(leftAnchor) > abs(rightAnchor) ? leftAnchor : rightAnchor
        let sign: Float = dominantAnchor < 0 ? -1 : 1

        if sign < 0 {
            newYValues = newYValues.map { $0 * sign }
            usedYValues = usedYValues.map { $0 * sign }
            deltas = deltas.map { $0 * sign }
        }

        let xOffset = xValues.first ?? 0
        let samples: [ProfileSample] = zip(zip(xValues, newYValues), zip(usedYValues, deltas)).map { pair in
            let lhs = pair.0
            let rhs = pair.1
            let xMM = Double((lhs.0 - xOffset) * 1_000)
            let newYMM = Double(lhs.1 * 1_000)
            let usedYMM = Double(rhs.0 * 1_000)
            let deltaMM = Double(rhs.1 * 1_000)
            return ProfileSample(xMM: xMM, newYMM: newYMM, usedYMM: usedYMM, deltaMM: deltaMM)
        }

        let absoluteMM = deltas.map { abs($0) * 1_000 }
        let positiveMM = deltas.filter { $0 > 0 }.map { $0 * 1_000 }

        return ProfileComputationResult(
            samples: samples,
            meanAbsDeltaMM: average(absoluteMM),
            p95AbsDeltaMM: percentile(of: absoluteMM, p: 0.95),
            maxAbsDeltaMM: absoluteMM.max() ?? 0,
            estimatedShoulderWearMM: positiveMM.isEmpty ? 0 : percentile(of: positiveMM, p: 0.95),
            overlapLengthMM: (xValues.last! - xValues.first!) * 1_000
        )
    }

    private static func project(points: [SIMD3<Float>],
                                center: SIMD3<Float>,
                                basis: simd_float3x3) -> [ProjectedPoint] {
        points.map { point in
            let delta = point - center
            return ProjectedPoint(
                x: simd_dot(delta, basis.columns.0),
                y: simd_dot(delta, basis.columns.1),
                z: simd_dot(delta, basis.columns.2)
            )
        }
    }

    private static func filterNearPlane(_ points: [ProjectedPoint]) -> [ProjectedPoint] {
        guard !points.isEmpty else { return [] }
        let absZ = points.map { abs($0.z) }
        let threshold = max(0.00075, percentile(of: absZ, p: 0.85))
        return points.filter { abs($0.z) <= threshold }
    }

    private static func overlappedXRange(new: [ProjectedPoint], used: [ProjectedPoint]) -> ClosedRange<Float>? {
        guard let newMin = new.map(\.x).min(),
              let newMax = new.map(\.x).max(),
              let usedMin = used.map(\.x).min(),
              let usedMax = used.map(\.x).max() else {
            return nil
        }

        let lower = max(newMin, usedMin)
        let upper = min(newMax, usedMax)
        guard upper > lower else { return nil }
        return lower ... upper
    }

    private static func binnedMedianCurve(points: [ProjectedPoint],
                                          xRange: ClosedRange<Float>,
                                          bins: Int) -> [Float?] {
        guard bins > 0 else { return [] }

        var buckets = Array(repeating: [Float](), count: bins)
        let width = max(xRange.upperBound - xRange.lowerBound, 0.000_001)

        for point in points where xRange.contains(point.x) {
            let normalized = (point.x - xRange.lowerBound) / width
            let index = min(bins - 1, max(0, Int(normalized * Float(bins))))
            buckets[index].append(point.y)
        }

        return buckets.map { bucket in
            median(of: bucket)
        }
    }

    private static func interpolateMissingValues(_ values: [Float?]) -> [Float?] {
        guard !values.isEmpty else { return values }
        var filled = values

        for index in filled.indices where filled[index] == nil {
            let leftIndex = stride(from: index - 1, through: 0, by: -1).first(where: { filled[$0] != nil })
            let rightIndex = stride(from: index + 1, to: filled.count, by: 1).first(where: { filled[$0] != nil })

            if let leftIndex, let rightIndex, let left = filled[leftIndex], let right = filled[rightIndex] {
                let t = Float(index - leftIndex) / Float(rightIndex - leftIndex)
                filled[index] = left + (right - left) * t
            }
        }

        return filled
    }
}
