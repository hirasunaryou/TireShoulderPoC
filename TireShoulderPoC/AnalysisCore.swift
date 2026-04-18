import Foundation
import simd

enum AnalysisCore {
    static func compare(newModel: LoadedModelPackage,
                        usedModel: LoadedModelPackage,
                        config: AnalysisConfig) throws -> ComparisonResult {
        let newBlue = simdPoints(newModel.bluePoints)
        let usedBlue = simdPoints(usedModel.bluePoints)

        let alignment = try ICPAligner.align(source: usedBlue,
                                             target: newBlue,
                                             config: config)

        let usedRedAligned = transformPoints(simdPoints(usedModel.redPoints),
                                             by: alignment.transform)
        let newRed = simdPoints(newModel.redPoints)

        let profile = try ProfileAnalyzer.compare(newPoints: newRed,
                                                  usedPointsAligned: usedRedAligned,
                                                  config: config)

        return ComparisonResult(
            usedToNew: Transform4x4(alignment.transform),
            initialAlignmentRMSMM: alignment.initialRMS,
            alignmentRMSMM: alignment.finalRMS,
            newBlueCount: newModel.bluePoints.count,
            usedBlueCount: usedModel.bluePoints.count,
            newRedCount: newModel.redPoints.count,
            usedRedCount: usedModel.redPoints.count,
            meanAbsDeltaMM: profile.meanAbsDeltaMM,
            p95AbsDeltaMM: profile.p95AbsDeltaMM,
            maxAbsDeltaMM: profile.maxAbsDeltaMM,
            estimatedShoulderWearMM: profile.estimatedShoulderWearMM,
            overlapLengthMM: profile.overlapLengthMM,
            samples: profile.samples
        )
    }
}
