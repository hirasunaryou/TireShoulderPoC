import Foundation
import simd

struct AlignmentComputationResult {
    let transform: simd_float4x4
    let initialRMS: Float
    let finalRMS: Float
}

enum ICPAligner {
    static func align(source originalSource: [SIMD3<Float>],
                      target originalTarget: [SIMD3<Float>],
                      config: AnalysisConfig) throws -> AlignmentComputationResult {
        guard originalSource.count >= config.minimumMaskPoints else {
            throw PoCError.alignmentFailed("走行品の青点群が少なすぎます。\(originalSource.count) 点しかありません。")
        }
        guard originalTarget.count >= config.minimumMaskPoints else {
            throw PoCError.alignmentFailed("新品の青点群が少なすぎます。\(originalTarget.count) 点しかありません。")
        }

        let source = voxelDownsample(originalSource, size: config.maskVoxelSizeMeters, limit: config.icpSampleLimit)
        let target = voxelDownsample(originalTarget, size: config.maskVoxelSizeMeters, limit: config.icpSampleLimit)

        var currentTransform = initialTransformPCA(source: source, target: target)
        let initialRMS = rmsNearestNeighbor(source: source, target: target, transform: currentTransform)

        var previousRMS = initialRMS

        for _ in 0..<config.icpMaxIterations {
            let transformed = transformPoints(source, by: currentTransform)
            let correspondences = trimmedCorrespondences(sourceTransformed: transformed,
                                                         target: target,
                                                         keepFraction: config.icpTrimFraction)

            guard correspondences.sourcePoints.count >= 3 else {
                throw PoCError.alignmentFailed("ICPの対応点が不足しました。")
            }

            let deltaTransform = bestRigidTransform(from: correspondences.sourcePoints,
                                                    to: correspondences.targetPoints)
            currentTransform = deltaTransform * currentTransform

            let nextRMS = rmsNearestNeighbor(source: source,
                                             target: target,
                                             transform: currentTransform)

            if abs(previousRMS - nextRMS) < config.icpConvergenceEpsilonMeters {
                previousRMS = nextRMS
                break
            }

            previousRMS = nextRMS
        }

        return AlignmentComputationResult(
            transform: currentTransform,
            initialRMS: initialRMS * 1_000,
            finalRMS: previousRMS * 1_000
        )
    }

    private static func initialTransformPCA(source: [SIMD3<Float>],
                                            target: [SIMD3<Float>]) -> simd_float4x4 {
        let sourcePCA = pca(of: source)
        let targetPCA = pca(of: target)

        let signVariants: [SIMD3<Float>] = [
            SIMD3<Float>(1, 1, 1),
            SIMD3<Float>(-1, -1, 1),
            SIMD3<Float>(-1, 1, -1),
            SIMD3<Float>(1, -1, -1)
        ]

        let evaluationSource = Array(source.prefix(240))

        var bestTransform = matrix_identity_float4x4
        var bestScore = Float.greatestFiniteMagnitude

        for signs in signVariants {
            let signMatrix = simd_float3x3(diagonal: signs)
            let rotation = targetPCA.basis * signMatrix * simd_transpose(sourcePCA.basis)
            let translation = targetPCA.center - rotation * sourcePCA.center
            let candidate = makeTransform(rotation: rotation, translation: translation)
            let score = rmsNearestNeighbor(source: evaluationSource, target: target, transform: candidate)

            if score < bestScore {
                bestScore = score
                bestTransform = candidate
            }
        }

        return bestTransform
    }

    private static func trimmedCorrespondences(sourceTransformed: [SIMD3<Float>],
                                               target: [SIMD3<Float>],
                                               keepFraction: Float) -> (sourcePoints: [SIMD3<Float>], targetPoints: [SIMD3<Float>], distancesSquared: [Float]) {
        var tuples: [(source: SIMD3<Float>, target: SIMD3<Float>, distanceSquared: Float)] = []
        tuples.reserveCapacity(sourceTransformed.count)

        for point in sourceTransformed {
            let nearest = nearestNeighbor(of: point, in: target)
            tuples.append((source: point, target: target[nearest.index], distanceSquared: nearest.distanceSquared))
        }

        tuples.sort { $0.distanceSquared < $1.distanceSquared }

        let keepCount = max(3, Int(Float(tuples.count) * clamped(keepFraction, Float(0.1) ... Float(1.0))))
        let kept = tuples.prefix(keepCount)

        let sourcePoints = kept.map(\.source)
        let targetPoints = kept.map(\.target)
        let distancesSquared = kept.map(\.distanceSquared)

        return (sourcePoints, targetPoints, distancesSquared)
    }
}
