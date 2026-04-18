import Foundation
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
    private enum MaterialChannel: String, CaseIterable {
        case diffuse
        case emission
        case multiply
        case selfIllumination
        case transparent
        case metalness
        case roughness
    }

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
        // NOTE: 現在は SceneKit material のみをサンプル対象にしている。
        // 将来は Model I/O の baseColor（MDLMaterialSemantic.baseColor）を優先サンプルし、
        // USDZ の PBR パイプラインに合わせたマスク抽出へ切り替える想定。
        if let imageHit = TextureSampler.extractCGImage(from: material),
           let prepared = TextureSampler.prepareRGBA(cgImage: imageHit.cgImage) {
            self.mode = .image(width: prepared.width, height: prepared.height, pixels: prepared.pixels)
            self.hasImageTexture = true
            self.hasFlatColor = false
            self.sourceSummary = "image[\(imageHit.channel.rawValue)](\(prepared.width)x\(prepared.height))"
            return
        }

        if let flatHit = TextureSampler.extractFlatColor(from: material) {
            self.mode = .flat(flatHit.color)
            self.hasImageTexture = false
            self.hasFlatColor = true
            self.sourceSummary = "flatColor[\(flatHit.channel.rawValue)]"
            return
        }

        self.mode = .unavailable
        self.hasImageTexture = false
        self.hasFlatColor = false
        self.sourceSummary = "unavailable"
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

    private static func extractCGImage(from material: SCNMaterial?) -> (channel: MaterialChannel, cgImage: CGImage)? {
        for channel in MaterialChannel.allCases {
            let candidate = contents(for: channel, in: material)
            switch candidate {
            case let image as UIImage:
                if let cgImage = image.cgImage {
                    return (channel, cgImage)
                }
            case let cgImage as CGImage:
                return (channel, cgImage)
            case let url as URL:
                if let image = UIImage(contentsOfFile: url.path), let cgImage = image.cgImage {
                    return (channel, cgImage)
                }
            case let path as String:
                if let image = UIImage(contentsOfFile: path), let cgImage = image.cgImage {
                    return (channel, cgImage)
                }
            default:
                continue
            }
        }

        return nil
    }

    private static func extractFlatColor(from material: SCNMaterial?) -> (channel: MaterialChannel, color: SIMD3<Float>)? {
        for channel in MaterialChannel.allCases {
            let candidate = contents(for: channel, in: material)
            if let color = candidate as? UIColor {
                var red: CGFloat = 0
                var green: CGFloat = 0
                var blue: CGFloat = 0
                var alpha: CGFloat = 0
                if color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
                    return (channel, SIMD3<Float>(Float(red), Float(green), Float(blue)))
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

    private static func contents(for channel: MaterialChannel, in material: SCNMaterial?) -> Any? {
        switch channel {
        case .diffuse:
            return material?.diffuse.contents
        case .emission:
            return material?.emission.contents
        case .multiply:
            return material?.multiply.contents
        case .selfIllumination:
            return material?.selfIllumination.contents
        case .transparent:
            return material?.transparent.contents
        case .metalness:
            return material?.metalness.contents
        case .roughness:
            return material?.roughness.contents
        }
    }
}

enum USDZLoader {
    private static let maxCachedSamples = 12_000

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
        var skippedNoUVTriangles = 0
        var materialRecords: [MaterialInspectionRecord] = []
        var modelIOMaterialRecords: [ModelIOMaterialInspectionRecord] = []
        var cachedSamples: [CachedCentroidSample] = []
        var warnings: [String] = []

        do {
            modelIOMaterialRecords = try inspectModelIOMaterials(url: url)
        } catch {
            // デバッグ情報の補助経路なので、ここが失敗しても取り込みは継続する。
            warnings.append("Model I/O inspection failed: \(error.localizedDescription)")
        }

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
                    lightingModelName: material?.lightingModel.rawValue ?? "(unknown)",
                    diffuseContentType: runtimeTypeName(material?.diffuse.contents),
                    emissionContentType: runtimeTypeName(material?.emission.contents),
                    multiplyContentType: runtimeTypeName(material?.multiply.contents),
                    selfIlluminationContentType: runtimeTypeName(material?.selfIllumination.contents),
                    transparentContentType: runtimeTypeName(material?.transparent.contents),
                    metalnessContentType: runtimeTypeName(material?.metalness.contents),
                    roughnessContentType: runtimeTypeName(material?.roughness.contents),
                    diffuseTransformIdentity: SCNMatrix4EqualToMatrix4(material?.diffuse.contentsTransform ?? SCNMatrix4Identity, SCNMatrix4Identity),
                    emissionTransformIdentity: SCNMatrix4EqualToMatrix4(material?.emission.contentsTransform ?? SCNMatrix4Identity, SCNMatrix4Identity),
                    multiplyTransformIdentity: SCNMatrix4EqualToMatrix4(material?.multiply.contentsTransform ?? SCNMatrix4Identity, SCNMatrix4Identity),
                    selfIlluminationTransformIdentity: SCNMatrix4EqualToMatrix4(material?.selfIllumination.contentsTransform ?? SCNMatrix4Identity, SCNMatrix4Identity),
                    transparentTransformIdentity: SCNMatrix4EqualToMatrix4(material?.transparent.contentsTransform ?? SCNMatrix4Identity, SCNMatrix4Identity),
                    metalnessTransformIdentity: SCNMatrix4EqualToMatrix4(material?.metalness.contentsTransform ?? SCNMatrix4Identity, SCNMatrix4Identity),
                    roughnessTransformIdentity: SCNMatrix4EqualToMatrix4(material?.roughness.contentsTransform ?? SCNMatrix4Identity, SCNMatrix4Identity),
                    transparency: Float(material?.transparency ?? 1)
                )
                materialRecords.append(record)
            }
        }

        let rawBlueCount = bluePoints.count
        let rawRedCount = redPoints.count
        let reducedBlue = voxelDownsample(bluePoints, size: config.maskVoxelSizeMeters)
        let reducedRed = voxelDownsample(redPoints, size: config.maskVoxelSizeMeters)

        if reducedBlue.count < config.minimumMaskPoints {
            warnings.append("青マスク不足: reduced=\(reducedBlue.count), raw=\(rawBlueCount), min=\(config.minimumMaskPoints)")
        }
        if reducedRed.count < config.minimumMaskPoints {
            warnings.append("赤マスク不足: reduced=\(reducedRed.count), raw=\(rawRedCount), min=\(config.minimumMaskPoints)")
        }
        if skippedNoUVTriangles > 0 {
            warnings.append("UVなし三角形のため画像テクスチャを未サンプリング: \(skippedNoUVTriangles)")
        }
        let cachedDiagnostics = makeCachedDiagnostics(from: cachedSamples)

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
            cachedDiagnostics: cachedDiagnostics,
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
            cachedDiagnostics: package.cachedDiagnostics,
            warnings: warnings
        )
    }

    private static func runtimeTypeName(_ value: Any?) -> String {
        guard let value else { return "nil" }
        return String(describing: type(of: value))
    }

    private static func inspectModelIOMaterials(url: URL) throws -> [ModelIOMaterialInspectionRecord] {
        let asset = MDLAsset(url: url)
        var records: [ModelIOMaterialInspectionRecord] = []

        // NOTE:
        // `childObjects(of:)` はアセット内を再帰的に走査して型一致オブジェクトを返すため、
        // API差異が出やすい `children` コンテナ直接操作より移植性が高い。
        if let meshes = asset.childObjects(of: MDLMesh.self) as? [MDLMesh] {
            for mesh in meshes {
                collectModelIOMaterials(from: mesh, records: &records)
            }
        }
        return records
    }

    private static func collectModelIOMaterials(from mesh: MDLMesh,
                                                records: inout [ModelIOMaterialInspectionRecord]) {
        guard let submeshContainer = mesh.submeshes else { return }

        for submeshIndex in 0..<submeshContainer.count {
            guard let submesh = submeshContainer[submeshIndex] as? MDLSubmesh,
                  let material = submesh.material else { continue }

            let baseColor = material.property(with: .baseColor)
            let materialName = material.name.isEmpty ? "(no-material-name)" : material.name

            records.append(
                ModelIOMaterialInspectionRecord(
                    meshName: mesh.name.isEmpty ? "(no-mesh-name)" : mesh.name,
                    submeshIndex: submeshIndex,
                    materialName: materialName,
                    semanticSummary: materialPropertiesSummary(material: material),
                    hasBaseColor: baseColor != nil,
                    baseColorKind: describeModelIOBaseColor(baseColor)
                )
            )
        }
    }

    private static func materialPropertiesSummary(material: MDLMaterial) -> String {
        var names: [String] = []
        for index in 0..<material.count {
            let property = material.property(at: index)
            names.append(String(describing: property.semantic))
        }
        return names.isEmpty ? "(none)" : names.joined(separator: ", ")
    }

    private static func describeModelIOBaseColor(_ property: MDLMaterialProperty?) -> String {
        guard let property else { return "none" }
        switch property.type {
        case .texture:
            return "texture"
        case .URL:
            return "url"
        case .string:
            return "string-path"
        case .float, .float2, .float3, .float4, .color:
            return "float/color"
        default:
            return "other(\(property.type.rawValue))"
        }
    }

    private static func makeCachedDiagnostics(from samples: [CachedCentroidSample]) -> CachedSampleDiagnostics? {
        guard !samples.isEmpty else { return nil }

        let count = Float(samples.count)
        var rgbSum = SIMD3<Float>(repeating: 0)
        var hsvSum = SIMD3<Float>(repeating: 0)
        var minSaturation = Float.greatestFiniteMagnitude
        var maxSaturation: Float = 0
        var minValue = Float.greatestFiniteMagnitude
        var maxValue: Float = 0
        var hueBuckets = [Int](repeating: 0, count: 12) // 30度刻み

        for sample in samples {
            rgbSum += sample.rgb
            hsvSum += SIMD3<Float>(sample.hsv.hue, sample.hsv.saturation, sample.hsv.value)
            minSaturation = min(minSaturation, sample.hsv.saturation)
            maxSaturation = max(maxSaturation, sample.hsv.saturation)
            minValue = min(minValue, sample.hsv.value)
            maxValue = max(maxValue, sample.hsv.value)

            let bucket = Int(sample.hsv.hue / 30).clamped(to: 0...11)
            hueBuckets[bucket] += 1
        }

        return CachedSampleDiagnostics(
            meanRGB: rgbSum / count,
            meanHSV: hsvSum / count,
            minSaturation: minSaturation,
            maxSaturation: maxSaturation,
            minValue: minValue,
            maxValue: maxValue,
            hueBucketCounts: hueBuckets
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

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
