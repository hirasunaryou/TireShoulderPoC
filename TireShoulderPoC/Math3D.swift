import Foundation
import simd

struct PCAResult {
    let center: SIMD3<Float>
    let basis: simd_float3x3
    let eigenvalues: [Float]
}

func simdPoints(_ points: [Point3]) -> [SIMD3<Float>] {
    points.map(\.simd)
}

func centroid(_ points: [SIMD3<Float>]) -> SIMD3<Float> {
    guard !points.isEmpty else { return .zero }
    var sum = SIMD3<Float>.zero
    for point in points {
        sum += point
    }
    return sum / Float(points.count)
}

func covarianceMatrix(of points: [SIMD3<Float>], around center: SIMD3<Float>) -> simd_float3x3 {
    guard points.count >= 2 else { return matrix_identity_float3x3 }

    var xx: Float = 0
    var xy: Float = 0
    var xz: Float = 0
    var yy: Float = 0
    var yz: Float = 0
    var zz: Float = 0

    for point in points {
        let d = point - center
        xx += d.x * d.x
        xy += d.x * d.y
        xz += d.x * d.z
        yy += d.y * d.y
        yz += d.y * d.z
        zz += d.z * d.z
    }

    let scale = 1 / Float(max(1, points.count - 1))

    return simd_float3x3(columns: (
        SIMD3<Float>(xx * scale, xy * scale, xz * scale),
        SIMD3<Float>(xy * scale, yy * scale, yz * scale),
        SIMD3<Float>(xz * scale, yz * scale, zz * scale)
    ))
}

private func matGet(_ matrix: simd_float3x3, row: Int, col: Int) -> Float {
    matrix[col][row]
}

private func matSet(_ matrix: inout simd_float3x3, row: Int, col: Int, value: Float) {
    matrix[col][row] = value
}

func eigenDecompositionSymmetric3x3(_ matrix: simd_float3x3) -> ([Float], [SIMD3<Float>]) {
    var a = matrix
    var v = matrix_identity_float3x3

    for _ in 0..<24 {
        let offDiagonalPairs = [
            (0, 1, abs(matGet(a, row: 0, col: 1))),
            (0, 2, abs(matGet(a, row: 0, col: 2))),
            (1, 2, abs(matGet(a, row: 1, col: 2)))
        ]

        guard let pivot = offDiagonalPairs.max(by: { $0.2 < $1.2 }) else { break }
        let p = pivot.0
        let q = pivot.1

        if pivot.2 < 1e-6 {
            break
        }

        let app = matGet(a, row: p, col: p)
        let aqq = matGet(a, row: q, col: q)
        let apq = matGet(a, row: p, col: q)

        let phi = 0.5 * atan2f(2 * apq, aqq - app)
        let c = cosf(phi)
        let s = sinf(phi)

        for i in 0..<3 where i != p && i != q {
            let aip = matGet(a, row: i, col: p)
            let aiq = matGet(a, row: i, col: q)

            let newAip = c * aip - s * aiq
            let newAiq = s * aip + c * aiq

            matSet(&a, row: i, col: p, value: newAip)
            matSet(&a, row: p, col: i, value: newAip)
            matSet(&a, row: i, col: q, value: newAiq)
            matSet(&a, row: q, col: i, value: newAiq)
        }

        let newApp = c * c * app - 2 * s * c * apq + s * s * aqq
        let newAqq = s * s * app + 2 * s * c * apq + c * c * aqq

        matSet(&a, row: p, col: p, value: newApp)
        matSet(&a, row: q, col: q, value: newAqq)
        matSet(&a, row: p, col: q, value: 0)
        matSet(&a, row: q, col: p, value: 0)

        for i in 0..<3 {
            let vip = matGet(v, row: i, col: p)
            let viq = matGet(v, row: i, col: q)

            let newVip = c * vip - s * viq
            let newViq = s * vip + c * viq

            matSet(&v, row: i, col: p, value: newVip)
            matSet(&v, row: i, col: q, value: newViq)
        }
    }

    let rawValues = [
        matGet(a, row: 0, col: 0),
        matGet(a, row: 1, col: 1),
        matGet(a, row: 2, col: 2)
    ]

    var pairs = [
        (value: rawValues[0], vector: v.columns.0),
        (value: rawValues[1], vector: v.columns.1),
        (value: rawValues[2], vector: v.columns.2)
    ]

    pairs.sort { $0.value > $1.value }

    var vectors = pairs.map { simd_normalize($0.vector) }
    if simd_dot(simd_cross(vectors[0], vectors[1]), vectors[2]) < 0 {
        vectors[2] *= -1
    }

    let values = pairs.map(\.value)
    return (values, vectors)
}

func pca(of points: [SIMD3<Float>]) -> PCAResult {
    let center = centroid(points)
    let covariance = covarianceMatrix(of: points, around: center)
    let (values, vectors) = eigenDecompositionSymmetric3x3(covariance)

    let basis = simd_float3x3(columns: (
        vectors[0],
        vectors[1],
        vectors[2]
    ))

    return PCAResult(center: center, basis: basis, eigenvalues: values)
}

func makeTransform(rotation: simd_float3x3, translation: SIMD3<Float>) -> simd_float4x4 {
    simd_float4x4(columns: (
        SIMD4<Float>(rotation.columns.0, 0),
        SIMD4<Float>(rotation.columns.1, 0),
        SIMD4<Float>(rotation.columns.2, 0),
        SIMD4<Float>(translation, 1)
    ))
}

func transformPoint(_ point: SIMD3<Float>, by transform: simd_float4x4) -> SIMD3<Float> {
    let result = transform * SIMD4<Float>(point, 1)
    return SIMD3<Float>(result.x, result.y, result.z)
}

func transformPoints(_ points: [SIMD3<Float>], by transform: simd_float4x4) -> [SIMD3<Float>] {
    points.map { transformPoint($0, by: transform) }
}

private func largestEigenvector(of matrix: simd_float4x4, iterations: Int = 48) -> SIMD4<Float> {
    var vector = simd_normalize(SIMD4<Float>(1, 0.5, 0.25, 0.125))

    for _ in 0..<iterations {
        let next = matrix * vector
        let length = simd_length(next)
        if length < 1e-8 {
            break
        }
        vector = next / length
    }

    return simd_normalize(vector)
}

func bestRigidTransform(from source: [SIMD3<Float>], to target: [SIMD3<Float>]) -> simd_float4x4 {
    guard source.count == target.count, source.count >= 3 else {
        return matrix_identity_float4x4
    }

    let sourceCenter = centroid(source)
    let targetCenter = centroid(target)

    var sxx: Float = 0
    var sxy: Float = 0
    var sxz: Float = 0
    var syx: Float = 0
    var syy: Float = 0
    var syz: Float = 0
    var szx: Float = 0
    var szy: Float = 0
    var szz: Float = 0

    for (pRaw, qRaw) in zip(source, target) {
        let p = pRaw - sourceCenter
        let q = qRaw - targetCenter

        sxx += p.x * q.x
        sxy += p.x * q.y
        sxz += p.x * q.z

        syx += p.y * q.x
        syy += p.y * q.y
        syz += p.y * q.z

        szx += p.z * q.x
        szy += p.z * q.y
        szz += p.z * q.z
    }

    let n = simd_float4x4(columns: (
        SIMD4<Float>(
            sxx + syy + szz,
            syz - szy,
            szx - sxz,
            sxy - syx
        ),
        SIMD4<Float>(
            syz - szy,
            sxx - syy - szz,
            sxy + syx,
            szx + sxz
        ),
        SIMD4<Float>(
            szx - sxz,
            sxy + syx,
            -sxx + syy - szz,
            syz + szy
        ),
        SIMD4<Float>(
            sxy - syx,
            szx + sxz,
            syz + szy,
            -sxx - syy + szz
        )
    ))

    let q = largestEigenvector(of: n)
    let quaternion = simd_quatf(ix: q.y, iy: q.z, iz: q.w, r: q.x)
    let rotation = simd_float3x3(quaternion)

    let translation = targetCenter - rotation * sourceCenter
    return makeTransform(rotation: rotation, translation: translation)
}

func nearestNeighbor(of point: SIMD3<Float>, in cloud: [SIMD3<Float>]) -> (index: Int, distanceSquared: Float) {
    guard let first = cloud.first else { return (0, .greatestFiniteMagnitude) }

    var bestIndex = 0
    var bestDistance = simd_length_squared(first - point)

    for (index, candidate) in cloud.enumerated().dropFirst() {
        let distance = simd_length_squared(candidate - point)
        if distance < bestDistance {
            bestDistance = distance
            bestIndex = index
        }
    }

    return (bestIndex, bestDistance)
}

func rmsNearestNeighbor(source: [SIMD3<Float>], target: [SIMD3<Float>], transform: simd_float4x4) -> Float {
    guard !source.isEmpty, !target.isEmpty else { return .greatestFiniteMagnitude }

    var distances: [Float] = []
    distances.reserveCapacity(source.count)

    for point in source {
        let transformed = transformPoint(point, by: transform)
        let (_, distanceSquared) = nearestNeighbor(of: transformed, in: target)
        distances.append(distanceSquared)
    }

    return sqrt(average(distances))
}
