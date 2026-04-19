import Foundation
import ImageIO
import ModelIO
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

    let hasImageTexture: Bool
    let hasFlatColor: Bool
    let sourceSummary: String

    private let mode: Mode

    init(material: SCNMaterial?) {
        if let cgImage = TextureSampler.extractCGImage(from: material),
           let prepared = TextureSampler.prepareRGBA(cgImage: cgImage) {
            self.mode = .image(width: prepared.width, height: prepared.height, pixels: prepared.pixels)
            self.hasImageTexture = true
            self.hasFlatColor = false
            self.sourceSummary = "image(\(prepared.width)x\(prepared.height))"
            return
        }

        if let color = TextureSampler.extractFlatColor(from: material) {
            self.mode = .flat(color)
            self.hasImageTexture = false
            self.hasFlatColor = true
            self.sourceSummary = "flatColor"
            return
        }

        self.mode = .unavailable
        self.hasImageTexture = false
        self.hasFlatColor = false
        self.sourceSummary = "unavailable"
    }

    init?(cgImage: CGImage) {
        guard let prepared = TextureSampler.prepareRGBA(cgImage: cgImage) else { return nil }
        self.mode = .image(width: prepared.width, height: prepared.height, pixels: prepared.pixels)
        self.hasImageTexture = true
        self.hasFlatColor = false
        self.sourceSummary = "image(\(prepared.width)x\(prepared.height))"
    }
    
    
    func sampleImage(at uv: SIMD2<Float>) -> SIMD3<Float>? {
        guard case .image(let width, let height, let pixels) = mode else { return nil }

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
    }

    var flatColor: SIMD3<Float>? {
        guard case .flat(let rgb) = mode else { return nil }
        return rgb
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
                if let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
                   let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) {
                    return cgImage
                }
                if let data = try? Data(contentsOf: url) {
                    if let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
                       let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) {
                        return cgImage
                    }
                    if let image = UIImage(data: data), let cgImage = image.cgImage {
                        return cgImage
                    }
                }
                if let image = UIImage(contentsOfFile: url.path), let cgImage = image.cgImage {
                    return cgImage
                }
            case let path as String:
                let fileURL = URL(fileURLWithPath: path)
                if let imageSource = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
                   let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) {
                    return cgImage
                }
                if let data = try? Data(contentsOf: fileURL) {
                    if let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
                       let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) {
                        return cgImage
                    }
                }
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
        guard let color = material?.diffuse.contents as? UIColor else { return nil }

        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        if color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            return SIMD3<Float>(Float(red), Float(green), Float(blue))
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
    private static let maxCachedSamples = 12_000

    static func inspect(url: URL, config: AnalysisConfig) throws -> LoadedModelPackage {
        let resolvedBaseColorTextureSamplers = loadResolvedModelIOBaseColorTextureSamplers(url: url)

        // SceneKitの既存抽出処理とは独立した最小診断としてModel I/O情報を取得する。
        let modelIOMaterialRecords = inspectModelIOMaterials(url: url)

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
        var skippedNoUVTriangles = 0
        var materialRecords: [MaterialInspectionRecord] = []
        var cachedSamples: [CachedCentroidSample] = []

        for node in geometryNodes {
            guard let geometry = node.geometry else { continue }
            guard let vertexSource = geometry.sources(for: .vertex).first else { continue }

            let localPositions = decodeVector3(source: vertexSource)
            guard !localPositions.isEmpty else { continue }

            let worldPositions = localPositions.map { transformPoint($0, by: node.simdWorldTransform) }
            let uvSource = geometry.sources(for: .texcoord).first
            let hasUV = uvSource != nil
            let uvs = uvSource.map { decodeVector2(source: $0) } ?? []

            let vertexColorSource = geometry.sources(for: .color).first
            let vertexColors = vertexColorSource.map { decodeColor(source: $0) } ?? []
            let hasVertexColor = !vertexColors.isEmpty

            for (elementIndex, element) in geometry.elements.enumerated() {
                let material = geometry.materials[safe: elementIndex] ?? geometry.firstMaterial
                let sampler = TextureSampler(material: material)
                let indices = decodeIndices(element: element)
                guard indices.count >= 3 else { continue }

                let triangleCount = indices.count / 3
                var sampledTriangleCount = 0

                for triangleStart in stride(from: 0, to: indices.count - 2, by: 3) {
                    let i0 = indices[triangleStart]
                    let i1 = indices[triangleStart + 1]
                    let i2 = indices[triangleStart + 2]

                    guard i0 < worldPositions.count,
                          i1 < worldPositions.count,
                          i2 < worldPositions.count else {
                        continue
                    }

                    let centroidPosition = (worldPositions[i0] + worldPositions[i1] + worldPositions[i2]) / 3

                    // 優先順位: 頂点色 > UV付き画像テクスチャ > フラット色 > 取得不可
                    let sampledRGB: SIMD3<Float>?
                    if hasVertexColor,
                       i0 < vertexColors.count,
                       i1 < vertexColors.count,
                       i2 < vertexColors.count {
                        sampledRGB = (vertexColors[i0] + vertexColors[i1] + vertexColors[i2]) / 3
                    } else if sampler.hasImageTexture {
                        if hasUV,
                           i0 < uvs.count,
                           i1 < uvs.count,
                           i2 < uvs.count {
                            let centroidUV = (uvs[i0] + uvs[i1] + uvs[i2]) / 3
                            sampledRGB = sampler.sampleImage(at: centroidUV)
                        } else {
                            skippedNoUVTriangles += 1
                            sampledRGB = nil
                        }
                    } else if hasUV,
                              i0 < uvs.count,
                              i1 < uvs.count,
                              i2 < uvs.count {
                        let fallbackSampler: TextureSampler?
                        if resolvedBaseColorTextureSamplers.count == 1 {
                            fallbackSampler = resolvedBaseColorTextureSamplers.first
                        } else if elementIndex < resolvedBaseColorTextureSamplers.count {
                            fallbackSampler = resolvedBaseColorTextureSamplers[elementIndex]
                        } else {
                            fallbackSampler = nil
                        }

                        if let fallbackSampler {
                            let centroidUV = (uvs[i0] + uvs[i1] + uvs[i2]) / 3
                            sampledRGB = fallbackSampler.sampleImage(at: centroidUV)
                        } else if let flatColor = sampler.flatColor {
                            sampledRGB = flatColor
                        } else {
                            sampledRGB = nil
                        }
                    } else if let flatColor = sampler.flatColor {
                        sampledRGB = flatColor
                    } else {
                        sampledRGB = nil
                    }

                    guard let rgb = sampledRGB else { continue }

                    sampledTriangleCount += 1
                    totalSamples += 1

                    let hsv = hsvColor(from: rgb)
                    if cachedSamples.count < maxCachedSamples {
                        cachedSamples.append(
                            CachedCentroidSample(
                                worldPosition: Point3(centroidPosition),
                                rgb: rgb,
                                hsv: hsv
                            )
                        )
                    }

                    switch classify(hsv: hsv, config: config) {
                    case .blue:
                        bluePoints.append(centroidPosition)
                    case .red:
                        redPoints.append(centroidPosition)
                    case .other:
                        break
                    }
                }

                let record = MaterialInspectionRecord(
                    nodeName: node.name ?? "(no-node-name)",
                    geometryName: geometry.name ?? "(no-geometry-name)",
                    materialIndex: elementIndex,
                    hasUV: hasUV,
                    hasVertexColor: hasVertexColor,
                    triangleCount: triangleCount,
                    sampledTriangleCount: sampledTriangleCount,
                    textureSourceSummary: sampler.sourceSummary,
                    diffuseType: material?.diffuse.contents.map { String(describing: type(of: $0)) },
                    emissionType: material?.emission.contents.map { String(describing: type(of: $0)) },
                    multiplyType: material?.multiply.contents.map { String(describing: type(of: $0)) },
                    selfIlluminationType: material?.selfIllumination.contents.map { String(describing: type(of: $0)) },
                    transparentType: material?.transparent.contents.map { String(describing: type(of: $0)) },
                    metalnessType: material?.metalness.contents.map { String(describing: type(of: $0)) },
                    roughnessType: material?.roughness.contents.map { String(describing: type(of: $0)) }
                )
                materialRecords.append(record)
            }
        }

        let rawBlueCount = bluePoints.count
        let rawRedCount = redPoints.count
        let reducedBlue = voxelDownsample(bluePoints, size: config.maskVoxelSizeMeters)
        let reducedRed = voxelDownsample(redPoints, size: config.maskVoxelSizeMeters)

        var warnings: [String] = []
        if reducedBlue.count < config.minimumMaskPoints {
            warnings.append("青マスク不足: reduced=\(reducedBlue.count), raw=\(rawBlueCount), min=\(config.minimumMaskPoints)")
        }
        if reducedRed.count < config.minimumMaskPoints {
            warnings.append("赤マスク不足: reduced=\(reducedRed.count), raw=\(rawRedCount), min=\(config.minimumMaskPoints)")
        }
        if skippedNoUVTriangles > 0 {
            warnings.append("UVなし三角形のため画像テクスチャを未サンプリング: \(skippedNoUVTriangles)")
        }

        let cachedStats = summarizeCachedSamples(cachedSamples)

        return LoadedModelPackage(
            displayName: url.deletingPathExtension().lastPathComponent,
            bluePoints: reducedBlue.map(Point3.init),
            redPoints: reducedRed.map(Point3.init),
            geometryNodeCount: geometryNodes.count,
            totalSamples: totalSamples,
            rawBlueCount: rawBlueCount,
            rawRedCount: rawRedCount,
            skippedNoUVTriangles: skippedNoUVTriangles,
            materialRecords: materialRecords,
            modelIOMaterialRecords: modelIOMaterialRecords,
            cachedSamples: cachedSamples,
            meanR: cachedStats.meanR,
            meanG: cachedStats.meanG,
            meanB: cachedStats.meanB,
            meanHue: cachedStats.meanHue,
            meanSaturation: cachedStats.meanSaturation,
            meanValue: cachedStats.meanValue,
            minSaturationObserved: cachedStats.minSaturationObserved,
            maxSaturationObserved: cachedStats.maxSaturationObserved,
            minValueObserved: cachedStats.minValueObserved,
            maxValueObserved: cachedStats.maxValueObserved,
            warnings: warnings
        )
    }

    static func reextractMasks(from package: LoadedModelPackage, config: AnalysisConfig) -> LoadedModelPackage {
        var bluePoints: [SIMD3<Float>] = []
        var redPoints: [SIMD3<Float>] = []

        for sample in package.cachedSamples {
            switch classify(hsv: sample.hsv, config: config) {
            case .blue:
                bluePoints.append(sample.worldPosition.simd)
            case .red:
                redPoints.append(sample.worldPosition.simd)
            case .other:
                break
            }
        }

        let reducedBlue = voxelDownsample(bluePoints, size: config.maskVoxelSizeMeters)
        let reducedRed = voxelDownsample(redPoints, size: config.maskVoxelSizeMeters)

        var warnings = package.warnings.filter { !$0.contains("マスク不足") }
        if reducedBlue.count < config.minimumMaskPoints {
            warnings.append("青マスク不足: reduced=\(reducedBlue.count), raw=\(bluePoints.count), min=\(config.minimumMaskPoints)")
        }
        if reducedRed.count < config.minimumMaskPoints {
            warnings.append("赤マスク不足: reduced=\(reducedRed.count), raw=\(redPoints.count), min=\(config.minimumMaskPoints)")
        }

        return LoadedModelPackage(
            displayName: package.displayName,
            bluePoints: reducedBlue.map(Point3.init),
            redPoints: reducedRed.map(Point3.init),
            geometryNodeCount: package.geometryNodeCount,
            totalSamples: package.totalSamples,
            rawBlueCount: bluePoints.count,
            rawRedCount: redPoints.count,
            skippedNoUVTriangles: package.skippedNoUVTriangles,
            materialRecords: package.materialRecords,
            modelIOMaterialRecords: package.modelIOMaterialRecords,
            cachedSamples: package.cachedSamples,
            meanR: package.meanR,
            meanG: package.meanG,
            meanB: package.meanB,
            meanHue: package.meanHue,
            meanSaturation: package.meanSaturation,
            meanValue: package.meanValue,
            minSaturationObserved: package.minSaturationObserved,
            maxSaturationObserved: package.maxSaturationObserved,
            minValueObserved: package.minValueObserved,
            maxValueObserved: package.maxValueObserved,
            warnings: warnings
        )
    }

    private static func inspectModelIOMaterials(url: URL) -> [ModelIOMaterialInspectionRecord] {
        let asset = MDLAsset(url: url)
        asset.loadTextures()
        let meshes = asset.childObjects(of: MDLMesh.self) as? [MDLMesh] ?? []
        var records: [ModelIOMaterialInspectionRecord] = []

        for mesh in meshes {
            let meshName = mesh.name.isEmpty ? "(no-mesh-name)" : mesh.name
            let submeshes = mesh.submeshes as? [Any] ?? []

            if submeshes.isEmpty {
                records.append(
                    ModelIOMaterialInspectionRecord(
                        meshName: meshName,
                        submeshIndex: 0,
                        hasMaterial: false,
                        hasBaseColor: false
                    )
                )
                continue
            }

            for (submeshIndex, anySubmesh) in submeshes.enumerated() {
                let material = (anySubmesh as? MDLSubmesh)?.material
                let baseColor = material?.property(with: .baseColor)
                let textureSampler = baseColor?.textureSamplerValue
                let texture = textureSampler?.texture
                let hasImageFromTexture = texture?.imageFromTexture() != nil
                let texelDataCount = texture?.texelDataWithTopLeftOrigin()?.count
                let baseColorTypeRawValue = baseColor.map { String($0.type.rawValue) } ?? "nil"
                print(
                    "[ModelIO.baseColor] mesh=\(meshName) submesh=\(submeshIndex) hasMaterial=\(material != nil) hasBaseColor=\(baseColor != nil) typeRaw=\(baseColorTypeRawValue) url=\(baseColor?.urlValue?.absoluteString ?? "nil") string=\(baseColor?.stringValue ?? "nil") hasSampler=\(textureSampler != nil) hasTexture=\(texture != nil) textureClass=\(texture.map { String(describing: type(of: $0)) } ?? "nil") textureDimensions=\(String(describing: texture?.dimensions)) hasImageFromTexture=\(hasImageFromTexture) texelDataCount=\(texelDataCount.map(String.init) ?? "nil")"
                )
                records.append(
                    ModelIOMaterialInspectionRecord(
                        meshName: meshName,
                        submeshIndex: submeshIndex,
                        hasMaterial: material != nil,
                        hasBaseColor: material?.property(with: .baseColor) != nil
                    )
                )
            }
        }

        return records
    }

    private static func loadResolvedModelIOBaseColorTextureSamplers(url: URL) -> [TextureSampler] {
        let asset = MDLAsset(url: url)
        asset.loadTextures()

        let meshes = asset.childObjects(of: MDLMesh.self) as? [MDLMesh] ?? []
        var samplers: [TextureSampler] = []

        for mesh in meshes {
            let submeshes = mesh.submeshes as? [Any] ?? []
            for anySubmesh in submeshes {
                guard let material = (anySubmesh as? MDLSubmesh)?.material,
                      let texture = material.property(with: .baseColor)?.textureSamplerValue?.texture,
                      let cgImage = texture.imageFromTexture(),
                      let sampler = TextureSampler(cgImage: cgImage) else {
                    continue
                }
                samplers.append(sampler)
            }
        }

        return samplers
    }
    
    
    private static func summarizeCachedSamples(_ samples: [CachedCentroidSample]) -> (
        meanR: Float,
        meanG: Float,
        meanB: Float,
        meanHue: Float,
        meanSaturation: Float,
        meanValue: Float,
        minSaturationObserved: Float,
        maxSaturationObserved: Float,
        minValueObserved: Float,
        maxValueObserved: Float
    ) {
        guard !samples.isEmpty else {
            return (0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        }

        var sumR: Float = 0
        var sumG: Float = 0
        var sumB: Float = 0
        var sumHue: Float = 0
        var sumSaturation: Float = 0
        var sumValue: Float = 0
        var minSaturation = Float.greatestFiniteMagnitude
        var maxSaturation = -Float.greatestFiniteMagnitude
        var minValue = Float.greatestFiniteMagnitude
        var maxValue = -Float.greatestFiniteMagnitude

        for sample in samples {
            sumR += sample.rgb.x
            sumG += sample.rgb.y
            sumB += sample.rgb.z
            sumHue += sample.hsv.hue
            sumSaturation += sample.hsv.saturation
            sumValue += sample.hsv.value
            minSaturation = min(minSaturation, sample.hsv.saturation)
            maxSaturation = max(maxSaturation, sample.hsv.saturation)
            minValue = min(minValue, sample.hsv.value)
            maxValue = max(maxValue, sample.hsv.value)
        }

        let count = Float(samples.count)
        return (
            meanR: sumR / count,
            meanG: sumG / count,
            meanB: sumB / count,
            meanHue: sumHue / count,
            meanSaturation: sumSaturation / count,
            meanValue: sumValue / count,
            minSaturationObserved: minSaturation,
            maxSaturationObserved: maxSaturation,
            minValueObserved: minValue,
            maxValueObserved: maxValue
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

    private static func classify(hsv: HSVColor, config: AnalysisConfig) -> MaskColor {
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

    private static func hsvColor(from rgb: SIMD3<Float>) -> HSVColor {
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
        return HSVColor(hue: normalizedHue, saturation: saturation, value: maximum)
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

    private static func decodeColor(source: SCNGeometrySource) -> [SIMD3<Float>] {
        guard source.componentsPerVector >= 3 else { return [] }
        let data = source.data

        return (0..<source.vectorCount).map { index in
            let base = source.dataOffset + index * source.dataStride
            let r = readColorComponent(from: data, offset: base, bytesPerComponent: source.bytesPerComponent)
            let g = readColorComponent(from: data, offset: base + source.bytesPerComponent, bytesPerComponent: source.bytesPerComponent)
            let b = readColorComponent(from: data, offset: base + source.bytesPerComponent * 2, bytesPerComponent: source.bytesPerComponent)
            return SIMD3<Float>(r, g, b)
        }
    }

    private static func readColorComponent(from data: Data, offset: Int, bytesPerComponent: Int) -> Float {
        switch bytesPerComponent {
        case 1:
            var value: UInt8 = 0
            _ = withUnsafeMutableBytes(of: &value) { buffer in
                data.copyBytes(to: buffer, from: offset ..< offset + 1)
            }
            return Float(value) / 255
        default:
            return readFloatComponent(from: data, offset: offset, bytesPerComponent: bytesPerComponent)
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
