import Foundation
import simd

enum LocalFileStore {
    static func importCopy(from sourceURL: URL, preferredName: String? = nil) throws -> URL {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let importDirectory = documentsDirectory.appendingPathComponent("ImportedUSDZ", isDirectory: true)

        if !FileManager.default.fileExists(atPath: importDirectory.path) {
            try FileManager.default.createDirectory(at: importDirectory, withIntermediateDirectories: true, attributes: nil)
        }

        let fileName = preferredName ?? sourceURL.lastPathComponent
        let destinationURL = importDirectory.appendingPathComponent("\(UUID().uuidString)-\(fileName)")

        let hasScopedAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasScopedAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            return destinationURL
        } catch {
            throw PoCError.fileImportFailed(error.localizedDescription)
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}

extension Float {
    var mmText: String {
        String(format: "%.2f mm", self)
    }
}

extension Double {
    var mmText: String {
        String(format: "%.2f mm", self)
    }
}

func percentile(of values: [Float], p: Float) -> Float {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let clamped = max(0, min(1, p))
    let index = Int(round(clamped * Float(sorted.count - 1)))
    return sorted[index]
}

func median(of values: [Float]) -> Float? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let midpoint = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
        return (sorted[midpoint - 1] + sorted[midpoint]) * 0.5
    } else {
        return sorted[midpoint]
    }
}

func movingAverage(_ values: [Float], radius: Int) -> [Float] {
    guard radius > 0, !values.isEmpty else { return values }
    return values.indices.map { index in
        let start = max(0, index - radius)
        let end = min(values.count - 1, index + radius)
        let slice = values[start ... end]
        let sum = slice.reduce(0, +)
        return sum / Float(slice.count)
    }
}

func average(_ values: [Float]) -> Float {
    guard !values.isEmpty else { return 0 }
    return values.reduce(0, +) / Float(values.count)
}

func average<T: BinaryFloatingPoint>(_ values: [T]) -> T {
    guard !values.isEmpty else { return 0 }
    return values.reduce(0, +) / T(values.count)
}

func clamped<T: Comparable>(_ value: T, _ range: ClosedRange<T>) -> T {
    min(range.upperBound, max(range.lowerBound, value))
}

struct VoxelKey: Hashable {
    let x: Int
    let y: Int
    let z: Int

    init(_ point: SIMD3<Float>, size: Float) {
        let safeSize = max(size, 0.000_001)
        self.x = Int(floor(point.x / safeSize))
        self.y = Int(floor(point.y / safeSize))
        self.z = Int(floor(point.z / safeSize))
    }
}

func voxelDownsample(_ points: [SIMD3<Float>], size: Float, limit: Int? = nil) -> [SIMD3<Float>] {
    guard !points.isEmpty else { return [] }

    var bins: [VoxelKey: (sum: SIMD3<Float>, count: Int)] = [:]
    bins.reserveCapacity(points.count / 2)

    for point in points {
        let key = VoxelKey(point, size: size)
        if var entry = bins[key] {
            entry.sum += point
            entry.count += 1
            bins[key] = entry
        } else {
            bins[key] = (sum: point, count: 1)
        }
    }

    var reduced = bins.values.map { entry in
        entry.sum / Float(entry.count)
    }

    if let limit, reduced.count > limit {
        let step = max(1, reduced.count / limit)
        reduced = reduced.enumerated().compactMap { index, value in
            index.isMultiple(of: step) ? value : nil
        }
        if reduced.count > limit {
            reduced = Array(reduced.prefix(limit))
        }
    }

    return reduced
}
