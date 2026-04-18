import Foundation
import SceneKit
import UIKit
import simd

private enum MaskColor {
    case blue
    case red
    case other
}

private struct TextureSampler {
    private enum Mode {
        case image(width: Int, height: Int, pixels: [UInt8])
        case flat(SIMD3<Float>)
        case unavailable
    }

    private let mode: Mode

    init(material: SCNMaterial?) {
        if let cgImage = TextureSampler.extractCGImage(from: material),
           let prepared = TextureSampler.prepareRGBA(cgImage: cgImage) {
            self.mode = .image(width: prepared.width, height: prepared.height, pixels: prepared.pixels)
            return
        }

        if let color = TextureSampler.extractFlatColor(from: material) {
            self.mode = .flat(color)
            return
        }

        self.mode = .unavailable
    }

    func color(at uv: SIMD2<Float>) -> SIMD3<Float>? {
        switch mode {
        case .flat(let rgb):
            return rgb

        case .image(let width, let height, let pixels):
            let wrappedU = uv.x - floor(uv.x)
            var wrappedV = uv.y - floor(uv.y)
            wrappedV = 1 - wrappedV

            let x = min(width - 1, max(0, Int(round(wrappedU * Float(width - 1)))))
            let y = min(height - 1, max(0, Int(round(wrappedV * Float(height - 1)))))
            let index = (y * width + x) * 4

            guard index + 3 < pixels.count else { return nil }

            return SIMD3<Float>(
                Float(pixels[index]) / 255,
                Float(pixels[index + 1]) / 255,
                Float(pixels[index + 2]) / 255
            )

        case .unavailable:
            return nil
        }
    }

    private static func extractCGImage(from material: SCNMaterial?) -> CGImage? {
        let candidates: [Any?] = [
            material?.diffuse.contents,
            material?.emission.contents,
            material?.multiply.contents
        ]

        for candidate in candidates {
            switch candidate {
            case let image as UIImage:
                if let cgImage = image.cgImage {
                    return cgImage
                }
            case let cgImage as CGImage:
                return cgImage
            case let url as URL:
                if let image = UIImage(contentsOfFile: url.path), let cgImage = image.cgImage {
                    return cgImage
                }
            case let path as String:
                if let image = UIImage(contentsOfFile: path), let cgImage = image.cgImage {
                    return cgImage
                }
            default:
                continue
            }
        }

        return nil
    }

    private static func extractFlatColor(from material: SCNMaterial?) -> SIMD3<Float>? {
        let candidates: [Any?] = [
            material?.diffuse.contents,
            material?.emission.contents
        ]

        for candidate in candidates {
            if let color = candidate as? UIColor {
                var red: CGFloat = 0
                var green: CGFloat = 0
                var blue: CGFloat = 0
                var alpha: CGFloat = 0
                if color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
                    return SIMD3<Float>(Float(red), Float(green), Float(blue))
                }
            }
        }

        return nil
    }

    private static func prepareRGBA(cgImage: CGImage) -> (width: Int, height: Int, pixels: [UInt8])? {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        let success = pixels.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(data: baseAddress,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: width * 4,
                                          space: colorSpace,
                                          bitmapInfo: bitmapInfo) else {
                return false
            }

            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        return success ? (width, height, pixels) : nil
    }
}

enum USDZLoader {
    static func inspect(url: URL, config: AnalysisConfig) throws -> LoadedModelPackage {
        let scene: SCNScene
        do {
            scene = try SCNScene(url: url, options: nil)
        } catch {
            throw PoCError.sceneLoadFailed(error.localizedDescription)
        }

        var geometryNodes: [SCNNode] = []
        collectGeometryNodes(from: scene.rootNode, into: &geometryNodes)

        guard !geometryNodes.isEmpty else {
            throw PoCError.geometryMissing
        }

        var bluePoints: [SIMD3<Float>] = []
        var redPoints: [SIMD3<Float>] = []
        var totalSamples = 0

        for node in geometryNodes {
            guard let geometry = node.geometry else { continue }

            guard let vertexSource = geometry.sources(for: .vertex).first else { continue }
            let localPositions = decodeVector3(source: vertexSource)
            guard !localPositions.isEmpty else { continue }

            let worldPositions = localPositions.map { transformPoint($0, by: node.simdWorldTransform) }
            let uvSource = geometry.sources(for: .texcoord).first
            let uvs = uvSource.map { decodeVector2(source: $0) } ?? Array(repeating: .zero, count: localPositions.count)

            for (elementIndex, element) in geometry.elements.enumerated() {
                let material = geometry.materials[safe: elementIndex] ?? geometry.firstMaterial
                let sampler = TextureSampler(material: material)
                let indices = decodeIndices(element: element)

                guard indices.count >= 3 else { continue }

                for triangleStart in stride(from: 0, to: indices.count - 2, by: 3) {
                    let i0 = indices[triangleStart]
                    let i1 = indices[triangleStart + 1]
                    let i2 = indices[triangleStart + 2]

                    guard i0 < worldPositions.count,
                          i1 < worldPositions.count,
                          i2 < worldPositions.count,
                          i0 < uvs.count,
                          i1 < uvs.count,
                          i2 < uvs.count else {
                        continue
                    }

                    let centroidPosition = (worldPositions[i0] + worldPositions[i1] + worldPositions[i2]) / 3
                    let centroidUV = (uvs[i0] + uvs[i1] + uvs[i2]) / 3

                    guard let rgb = sampler.color(at: centroidUV) else { continue }
                    totalSamples += 1

                    switch classify(rgb: rgb, config: config) {
                    case .blue:
                        bluePoints.append(centroidPosition)
                    case .red:
                        redPoints.append(centroidPosition)
                    case .other:
                        break
                    }
                }
            }
        }

        let reducedBlue = voxelDownsample(bluePoints, size: config.maskVoxelSizeMeters)
        let reducedRed = voxelDownsample(redPoints, size: config.maskVoxelSizeMeters)

        guard reducedBlue.count >= config.minimumMaskPoints else {
            throw PoCError.maskExtractionFailed("青点は \(reducedBlue.count) 点でした。青テープをもっと広く、非対称に貼るか、照明を改善してください。")
        }

        guard reducedRed.count >= config.minimumMaskPoints else {
            throw PoCError.maskExtractionFailed("赤点は \(reducedRed.count) 点でした。赤テープ幅を広げるか、色の彩度を上げてください。")
        }

        return LoadedModelPackage(
            displayName: url.deletingPathExtension().lastPathComponent,
            bluePoints: reducedBlue.map(Point3.init),
            redPoints: reducedRed.map(Point3.init),
            totalSamples: totalSamples
        )
    }

    private static func collectGeometryNodes(from node: SCNNode, into storage: inout [SCNNode]) {
        if node.geometry != nil {
            storage.append(node)
        }

        for child in node.childNodes {
            collectGeometryNodes(from: child, into: &storage)
        }
    }

    private static func classify(rgb: SIMD3<Float>, config: AnalysisConfig) -> MaskColor {
        let hsv = hsvColor(from: rgb)
        guard hsv.saturation >= config.minSaturation, hsv.value >= config.minValue else {
            return .other
        }

        if config.blueHueRange.contains(hsv.hue) {
            return .blue
        }

        if config.redHueRanges.contains(where: { $0.contains(hsv.hue) }) {
            return .red
        }

        return .other
    }

    private static func hsvColor(from rgb: SIMD3<Float>) -> (hue: Float, saturation: Float, value: Float) {
        let r = rgb.x
        let g = rgb.y
        let b = rgb.z

        let maximum = max(r, max(g, b))
        let minimum = min(r, min(g, b))
        let delta = maximum - minimum

        let hue: Float
        if delta < 0.000_01 {
            hue = 0
        } else if maximum == r {
            hue = 60 * (((g - b) / delta).truncatingRemainder(dividingBy: 6))
        } else if maximum == g {
            hue = 60 * (((b - r) / delta) + 2)
        } else {
            hue = 60 * (((r - g) / delta) + 4)
        }

        let normalizedHue = hue < 0 ? hue + 360 : hue
        let saturation = maximum == 0 ? 0 : delta / maximum
        return (normalizedHue, saturation, maximum)
    }

    private static func decodeVector3(source: SCNGeometrySource) -> [SIMD3<Float>] {
        guard source.componentsPerVector >= 3 else { return [] }
        let data = source.data

        return (0..<source.vectorCount).map { index in
            let base = source.dataOffset + index * source.dataStride
            let x = readFloatComponent(from: data, offset: base, bytesPerComponent: source.bytesPerComponent)
            let y = readFloatComponent(from: data, offset: base + source.bytesPerComponent, bytesPerComponent: source.bytesPerComponent)
            let z = readFloatComponent(from: data, offset: base + source.bytesPerComponent * 2, bytesPerComponent: source.bytesPerComponent)
            return SIMD3<Float>(x, y, z)
        }
    }

    private static func decodeVector2(source: SCNGeometrySource) -> [SIMD2<Float>] {
        guard source.componentsPerVector >= 2 else { return [] }
        let data = source.data

        return (0..<source.vectorCount).map { index in
            let base = source.dataOffset + index * source.dataStride
            let x = readFloatComponent(from: data, offset: base, bytesPerComponent: source.bytesPerComponent)
            let y = readFloatComponent(from: data, offset: base + source.bytesPerComponent, bytesPerComponent: source.bytesPerComponent)
            return SIMD2<Float>(x, y)
        }
    }

    private static func readFloatComponent(from data: Data, offset: Int, bytesPerComponent: Int) -> Float {
        switch bytesPerComponent {
        case 2:
            var raw: UInt16 = 0
            _ = withUnsafeMutableBytes(of: &raw) { buffer in
                data.copyBytes(to: buffer, from: offset ..< offset + 2)
            }
            return Float(Float16(bitPattern: raw))
        case 4:
            var value: Float = 0
            _ = withUnsafeMutableBytes(of: &value) { buffer in
                data.copyBytes(to: buffer, from: offset ..< offset + 4)
            }
            return value
        case 8:
            var value: Double = 0
            _ = withUnsafeMutableBytes(of: &value) { buffer in
                data.copyBytes(to: buffer, from: offset ..< offset + 8)
            }
            return Float(value)
        default:
            return 0
        }
    }

    private static func decodeIndices(element: SCNGeometryElement) -> [Int] {
        let rawIndices: [Int]
        let indexCount: Int

        switch element.primitiveType {
        case .triangles:
            indexCount = element.primitiveCount * 3
        case .triangleStrip:
            indexCount = element.primitiveCount + 2
        default:
            return []
        }

        let data = element.data
        rawIndices = (0..<indexCount).map { readIndex(from: data, at: $0 * element.bytesPerIndex, bytesPerIndex: element.bytesPerIndex) }

        if element.primitiveType == .triangles {
            return rawIndices
        }

        var triangles: [Int] = []
        for i in 0..<(rawIndices.count - 2) {
            if i.isMultiple(of: 2) {
                triangles.append(contentsOf: [rawIndices[i], rawIndices[i + 1], rawIndices[i + 2]])
            } else {
                triangles.append(contentsOf: [rawIndices[i + 1], rawIndices[i], rawIndices[i + 2]])
            }
        }
        return triangles
    }

    private static func readIndex(from data: Data, at offset: Int, bytesPerIndex: Int) -> Int {
        switch bytesPerIndex {
        case 1:
            var value: UInt8 = 0
            _ = withUnsafeMutableBytes(of: &value) { buffer in
                data.copyBytes(to: buffer, from: offset ..< offset + 1)
            }
            return Int(value)
        case 2:
            var value: UInt16 = 0
            _ = withUnsafeMutableBytes(of: &value) { buffer in
                data.copyBytes(to: buffer, from: offset ..< offset + 2)
            }
            return Int(value)
        case 4:
            var value: UInt32 = 0
            _ = withUnsafeMutableBytes(of: &value) { buffer in
                data.copyBytes(to: buffer, from: offset ..< offset + 4)
            }
            return Int(value)
        default:
            return 0
        }
    }
}
