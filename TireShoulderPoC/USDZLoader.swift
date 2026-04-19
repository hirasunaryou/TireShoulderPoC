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

private struct BoundsAccumulator3D {
    private var minPoint: SIMD3<Float>?
    private var maxPoint: SIMD3<Float>?

    mutating func append(points: [SIMD3<Float>]) {
        for point in points {
            append(point: point)
        }
    }

    mutating func append(point: SIMD3<Float>) {
        if let minPoint, let maxPoint {
            self.minPoint = SIMD3<Float>(
                Swift.min(minPoint.x, point.x),
                Swift.min(minPoint.y, point.y),
                Swift.min(minPoint.z, point.z)
            )
            self.maxPoint = SIMD3<Float>(
                Swift.max(maxPoint.x, point.x),
                Swift.max(maxPoint.y, point.y),
                Swift.max(maxPoint.z, point.z)
            )
        } else {
            self.minPoint = point
            self.maxPoint = point
        }
    }

    func finalized() -> SpatialBounds3D {
        guard let minPoint, let maxPoint else {
            return SpatialBounds3D(min: Point3(x: 0, y: 0, z: 0), max: Point3(x: 0, y: 0, z: 0))
        }
        return SpatialBounds3D(min: Point3(minPoint), max: Point3(maxPoint))
    }
}

private extension SpatialBounds3D {
    func expanding(with point: SIMD3<Float>) -> SpatialBounds3D {
        SpatialBounds3D(
            min: Point3(
                x: Swift.min(min.x, point.x),
                y: Swift.min(min.y, point.y),
                z: Swift.min(min.z, point.z)
            ),
            max: Point3(
                x: Swift.max(max.x, point.x),
                y: Swift.max(max.y, point.y),
                z: Swift.max(max.z, point.z)
            )
        )
    }
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

        // Object Capture系のテクスチャは基本的にアトラス前提なので、
        // ラップより clamp のほうが seam 由来の誤検知を起こしにくい。
        let clampedU = max(0, min(1, uv.x))
        var clampedV = max(0, min(1, uv.y))
        clampedV = 1 - clampedV

        let x = min(width - 1, max(0, Int(round(clampedU * Float(width - 1)))))
        let y = min(height - 1, max(0, Int(round(clampedV * Float(height - 1)))))
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
    private static let maxCachedSamples = 24_000
    static var nearColorRichRadiusMeters: Float = 0.004

    enum ExtractionMode: String, CaseIterable {
        case simpleThreshold = "Simple Threshold"
        case nearColorRich = "Near Color-Rich"
    }

    static var extractionMode: ExtractionMode = .simpleThreshold

    static func inspect(url: URL, config: AnalysisConfig, roi: SpatialBounds3D?) throws -> LoadedModelPackage {
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

        var totalSamples = 0
        var skippedNoUVTriangles = 0
        var materialRecords: [MaterialInspectionRecord] = []
        var cachedSampleBins: [VoxelKey: CachedCentroidSample] = [:]
        var sourceBoundsAccumulator = BoundsAccumulator3D()

        for node in geometryNodes {
            guard let geometry = node.geometry else { continue }
            guard let vertexSource = geometry.sources(for: .vertex).first else { continue }

            let localPositions = decodeVector3(source: vertexSource)
            guard !localPositions.isEmpty else { continue }

            let worldPositions = localPositions.map { transformPoint($0, by: node.simdWorldTransform) }
            sourceBoundsAccumulator.append(points: worldPositions)
            let uvSource = geometry.sources(for: .texcoord).first
            let hasUV = uvSource != nil
            let uvs = uvSource.map { decodeVector2(source: $0) } ?? []

            let vertexColorSource = geometry.sources(for: .color).first
            let vertexColors = vertexColorSource.map { decodeColor(source: $0) } ?? []
            let hasVertexColor = !vertexColors.isEmpty

            for (elementIndex, element) in geometry.elements.enumerated() {
                let material = geometry.materials[safe: elementIndex] ?? geometry.firstMaterial
                let sampler = TextureSampler(material: material)
                let fallbackSampler = fallbackTextureSampler(
                    for: elementIndex,
                    resolvedBaseColorTextureSamplers: resolvedBaseColorTextureSamplers
                )
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

                    // ROIが設定されている場合は、色サンプリングに入る前に
                    // triangle AABB と ROI AABB の交差で早期除外する。
                    if let roi {
                        let triangleBounds = SpatialBounds3D(min: Point3(worldPositions[i0]), max: Point3(worldPositions[i0]))
                            .expanding(with: worldPositions[i1])
                            .expanding(with: worldPositions[i2])
                        guard triangleBounds.intersects(roi) else {
                            continue
                        }
                    }

                    guard let representativeSample = sampleRepresentative(
                        forTriangle: (i0, i1, i2),
                        worldPositions: worldPositions,
                        uvs: uvs,
                        hasUV: hasUV,
                        vertexColors: vertexColors,
                        hasVertexColor: hasVertexColor,
                        sampler: sampler,
                        fallbackSampler: fallbackSampler,
                        skippedNoUVTriangles: &skippedNoUVTriangles
                    ) else {
                        continue
                    }

                    sampledTriangleCount += 1
                    totalSamples += 1
                    cacheSample(
                        representativeSample,
                        into: &cachedSampleBins,
                        voxelSize: config.cacheVoxelSizeMeters
                    )
                }

                let record = MaterialInspectionRecord(
                    nodeName: node.name ?? "(no-node-name)",
                    geometryName: geometry.name ?? "(no-geometry-name)",
                    materialIndex: elementIndex,
                    hasUV: hasUV,
                    hasVertexColor: hasVertexColor,
                    triangleCount: triangleCount,
                    sampledTriangleCount: sampledTriangleCount,
                    textureSourceSummary: effectiveTextureSourceSummary(
                        primarySampler: sampler,
                        fallbackSampler: fallbackSampler,
                        hasVertexColor: hasVertexColor
                    ),
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

        var cachedSamples = reduceCachedSamplesIfNeeded(
            Array(cachedSampleBins.values),
            targetCount: maxCachedSamples,
            baseVoxelSize: config.cacheVoxelSizeMeters
        )
        cachedSamples.sort { lhs, rhs in
            if lhs.worldPosition.x != rhs.worldPosition.x { return lhs.worldPosition.x < rhs.worldPosition.x }
            if lhs.worldPosition.y != rhs.worldPosition.y { return lhs.worldPosition.y < rhs.worldPosition.y }
            return lhs.worldPosition.z < rhs.worldPosition.z
        }

        let colorRichSamples = cachedSamples.filter { isStrongColorSeed(rgb: $0.rgb, hsv: $0.hsv, config: config) }
        let classifiedPoints = classifySamples(cachedSamples, config: config)
        let bluePoints = classifiedPoints.bluePoints
        let redPoints = classifiedPoints.redPoints
        let rawBlueCount = classifiedPoints.blueCount
        let rawRedCount = classifiedPoints.redCount
        let reducedBlue = voxelDownsample(bluePoints, size: config.maskVoxelSizeMeters)
        let reducedRed = voxelDownsample(redPoints, size: config.maskVoxelSizeMeters)

        var warnings: [String] = []
        if cachedSamples.count < totalSamples {
            warnings.append("sample cache縮約: raw=\(totalSamples), cached=\(cachedSamples.count)")
        }
        if reducedBlue.count < config.minimumMaskPoints {
            warnings.append("青マスク不足: reduced=\(reducedBlue.count), raw=\(rawBlueCount), min=\(config.minimumMaskPoints)")
        }
        if reducedRed.count < config.minimumMaskPoints {
            warnings.append("赤マスク不足: reduced=\(reducedRed.count), raw=\(rawRedCount), min=\(config.minimumMaskPoints)")
        }
        if skippedNoUVTriangles > 0 {
            warnings.append("UVなし三角形のため画像テクスチャを未サンプリング: \(skippedNoUVTriangles)")
        }
        warnings.append("[ExtractionDebug] mode=\(extractionMode.rawValue) candidate=\(classifiedPoints.candidateCount) blue=\(classifiedPoints.blueCount) red=\(classifiedPoints.redCount)")

        let cachedStats = summarizeCachedSamples(cachedSamples)
        let sourceBounds = sourceBoundsAccumulator.finalized()
        logCachedSampleHSVDiagnostics(cachedSamples, colorRichSamples: colorRichSamples, config: config)

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
            sourceBounds: sourceBounds,
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
        let classifiedPoints = classifySamples(package.cachedSamples, config: config)
        let bluePoints = classifiedPoints.bluePoints
        let redPoints = classifiedPoints.redPoints

        let reducedBlue = voxelDownsample(bluePoints, size: config.maskVoxelSizeMeters)
        let reducedRed = voxelDownsample(redPoints, size: config.maskVoxelSizeMeters)

        var warnings = package.warnings.filter { !$0.contains("マスク不足") && !$0.contains("[ExtractionDebug]") }
        if reducedBlue.count < config.minimumMaskPoints {
            warnings.append("青マスク不足: reduced=\(reducedBlue.count), raw=\(bluePoints.count), min=\(config.minimumMaskPoints)")
        }
        if reducedRed.count < config.minimumMaskPoints {
            warnings.append("赤マスク不足: reduced=\(reducedRed.count), raw=\(redPoints.count), min=\(config.minimumMaskPoints)")
        }
        warnings.append("[ExtractionDebug] mode=\(extractionMode.rawValue) candidate=\(classifiedPoints.candidateCount) blue=\(classifiedPoints.blueCount) red=\(classifiedPoints.redCount)")

        return LoadedModelPackage(
            displayName: package.displayName,
            bluePoints: reducedBlue.map(Point3.init),
            redPoints: reducedRed.map(Point3.init),
            geometryNodeCount: package.geometryNodeCount,
            totalSamples: package.totalSamples,
            rawBlueCount: classifiedPoints.blueCount,
            rawRedCount: classifiedPoints.redCount,
            skippedNoUVTriangles: package.skippedNoUVTriangles,
            materialRecords: package.materialRecords,
            modelIOMaterialRecords: package.modelIOMaterialRecords,
            cachedSamples: package.cachedSamples,
            sourceBounds: package.sourceBounds,
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
                      let unmanagedImage = texture.imageFromTexture(),
                      let sampler = TextureSampler(cgImage: unmanagedImage.takeUnretainedValue()) else {
                    continue
                }
                samplers.append(sampler)
            }
        }

        return samplers
    }

    private struct TriangleRepresentativeSample {
        let worldPosition: SIMD3<Float>
        let rgb: SIMD3<Float>
        let hsv: HSVColor

        var colorfulnessScore: Float {
            let metrics = USDZLoader.colorMetrics(from: rgb)
            return (hsv.saturation * 1.6) + (metrics.chroma * 1.2) + (metrics.normalizedDominance * 0.9) + (hsv.value * 0.15)
        }
    }

    private struct ColorMetrics {
        let maxComponent: Float
        let minComponent: Float
        let secondComponent: Float
        let chroma: Float
        let normalizedDominance: Float
        let redDominance: Float
        let blueDominance: Float
    }

    private struct NeighborPointIndex {
        private struct CellKey: Hashable {
            let x: Int
            let y: Int
            let z: Int

            init(point: SIMD3<Float>, cellSize: Float) {
                let safeSize = max(cellSize, 0.000_001)
                self.x = Int(floor(point.x / safeSize))
                self.y = Int(floor(point.y / safeSize))
                self.z = Int(floor(point.z / safeSize))
            }

            init(x: Int, y: Int, z: Int) {
                self.x = x
                self.y = y
                self.z = z
            }
        }

        let cellSize: Float
        private let buckets: [CellKey: [SIMD3<Float>]]

        init(points: [SIMD3<Float>], cellSize: Float) {
            self.cellSize = max(cellSize, 0.00075)
            var buckets: [CellKey: [SIMD3<Float>]] = [:]
            buckets.reserveCapacity(points.count)
            for point in points {
                let key = CellKey(point: point, cellSize: self.cellSize)
                buckets[key, default: []].append(point)
            }
            self.buckets = buckets
        }

        func containsPoint(near point: SIMD3<Float>, radius: Float) -> Bool {
            let safeRadius = max(radius, 0.00075)
            let radiusSquared = safeRadius * safeRadius
            let centerKey = CellKey(point: point, cellSize: cellSize)
            let range = max(1, Int(ceil(safeRadius / cellSize)))

            for x in (centerKey.x - range)...(centerKey.x + range) {
                for y in (centerKey.y - range)...(centerKey.y + range) {
                    for z in (centerKey.z - range)...(centerKey.z + range) {
                        guard let bucket = buckets[CellKey(x: x, y: y, z: z)] else { continue }
                        for candidate in bucket where simd_distance_squared(candidate, point) <= radiusSquared {
                            return true
                        }
                    }
                }
            }
            return false
        }
    }

    private static let representativeTriangleSampleWeights: [SIMD3<Float>] = [
        SIMD3<Float>(1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0),
        SIMD3<Float>(0.60, 0.20, 0.20),
        SIMD3<Float>(0.20, 0.60, 0.20),
        SIMD3<Float>(0.20, 0.20, 0.60)
    ]

    private static func fallbackTextureSampler(for elementIndex: Int,
                                               resolvedBaseColorTextureSamplers: [TextureSampler]) -> TextureSampler? {
        _ = elementIndex
        // SceneKit geometry.element の index と Model I/O submesh の順序は必ずしも一致しない。
        // ここで無理に index 対応させると、別サブメッシュのテクスチャを誤サンプリングして
        // 「灰色のどこかが赤/青に見える」原因になる。
        // 安全に使えるのは単一テクスチャが明らかなケースだけに絞る。
        return resolvedBaseColorTextureSamplers.count == 1 ? resolvedBaseColorTextureSamplers.first : nil
    }

    private static func effectiveTextureSourceSummary(primarySampler: TextureSampler,
                                                      fallbackSampler: TextureSampler?,
                                                      hasVertexColor: Bool) -> String {
        if primarySampler.hasImageTexture {
            return "sceneTexture:\(primarySampler.sourceSummary)"
        }
        if let fallbackSampler {
            return "mdlBaseColor:\(fallbackSampler.sourceSummary)"
        }
        if hasVertexColor {
            return "vertexColor"
        }
        if primarySampler.hasFlatColor {
            return "flatColor"
        }
        return primarySampler.sourceSummary
    }

    private static func sampleRepresentative(
        forTriangle triangle: (Int, Int, Int),
        worldPositions: [SIMD3<Float>],
        uvs: [SIMD2<Float>],
        hasUV: Bool,
        vertexColors: [SIMD3<Float>],
        hasVertexColor: Bool,
        sampler: TextureSampler,
        fallbackSampler: TextureSampler?,
        skippedNoUVTriangles: inout Int
    ) -> CachedCentroidSample? {
        let (i0, i1, i2) = triangle
        let textureSampler = sampler.hasImageTexture ? sampler : fallbackSampler

        if let textureSampler {
            if hasUV,
               i0 < uvs.count,
               i1 < uvs.count,
               i2 < uvs.count,
               let texturedSample = texturedRepresentativeSample(
                    positions: (worldPositions[i0], worldPositions[i1], worldPositions[i2]),
                    uvs: (uvs[i0], uvs[i1], uvs[i2]),
                    sampler: textureSampler
               ) {
                return CachedCentroidSample(
                    worldPosition: Point3(texturedSample.worldPosition),
                    rgb: texturedSample.rgb,
                    hsv: texturedSample.hsv
                )
            }
            if !hasUV || i0 >= uvs.count || i1 >= uvs.count || i2 >= uvs.count {
                skippedNoUVTriangles += 1
            }
        }

        if hasVertexColor,
           i0 < vertexColors.count,
           i1 < vertexColors.count,
           i2 < vertexColors.count,
           let vertexColorSample = vertexColorRepresentativeSample(
                positions: (worldPositions[i0], worldPositions[i1], worldPositions[i2]),
                colors: (vertexColors[i0], vertexColors[i1], vertexColors[i2])
           ) {
            return CachedCentroidSample(
                worldPosition: Point3(vertexColorSample.worldPosition),
                rgb: vertexColorSample.rgb,
                hsv: vertexColorSample.hsv
            )
        }

        if let flatColor = sampler.flatColor,
           let flatColorSample = flatColorRepresentativeSample(
                positions: (worldPositions[i0], worldPositions[i1], worldPositions[i2]),
                rgb: flatColor
           ) {
            return CachedCentroidSample(
                worldPosition: Point3(flatColorSample.worldPosition),
                rgb: flatColorSample.rgb,
                hsv: flatColorSample.hsv
            )
        }

        return nil
    }

    private static func texturedRepresentativeSample(
        positions: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>),
        uvs: (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>),
        sampler: TextureSampler
    ) -> TriangleRepresentativeSample? {
        let (p0, p1, p2) = positions
        let (uv0, uv1, uv2) = uvs
        let candidates = representativeTriangleSampleWeights.compactMap { weights -> TriangleRepresentativeSample? in
            let uv = interpolateVector2(weights: weights, v0: uv0, v1: uv1, v2: uv2)
            guard let rgb = sampler.sampleImage(at: uv) else { return nil }
            let worldPosition = interpolateVector3(weights: weights, v0: p0, v1: p1, v2: p2)
            let hsv = hsvColor(from: rgb)
            return TriangleRepresentativeSample(worldPosition: worldPosition, rgb: rgb, hsv: hsv)
        }
        return representativeSample(from: candidates)
    }

    private static func vertexColorRepresentativeSample(
        positions: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>),
        colors: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)
    ) -> TriangleRepresentativeSample? {
        let (p0, p1, p2) = positions
        let (c0, c1, c2) = colors
        let candidates = representativeTriangleSampleWeights.map { weights -> TriangleRepresentativeSample in
            let rgb = interpolateVector3(weights: weights, v0: c0, v1: c1, v2: c2)
            let worldPosition = interpolateVector3(weights: weights, v0: p0, v1: p1, v2: p2)
            let hsv = hsvColor(from: rgb)
            return TriangleRepresentativeSample(worldPosition: worldPosition, rgb: rgb, hsv: hsv)
        }
        return representativeSample(from: candidates)
    }

    private static func flatColorRepresentativeSample(
        positions: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>),
        rgb: SIMD3<Float>
    ) -> TriangleRepresentativeSample? {
        let centroidWeights = representativeTriangleSampleWeights[0]
        let worldPosition = interpolateVector3(weights: centroidWeights, v0: positions.0, v1: positions.1, v2: positions.2)
        let hsv = hsvColor(from: rgb)
        return TriangleRepresentativeSample(worldPosition: worldPosition, rgb: rgb, hsv: hsv)
    }

    private static func representativeSample(from candidates: [TriangleRepresentativeSample]) -> TriangleRepresentativeSample? {
        candidates.max { lhs, rhs in
            lhs.colorfulnessScore < rhs.colorfulnessScore
        }
    }

    private static func cacheSample(_ sample: CachedCentroidSample,
                                    into bins: inout [VoxelKey: CachedCentroidSample],
                                    voxelSize: Float) {
        let key = VoxelKey(sample.worldPosition.simd, size: max(voxelSize, 0.00075))
        if let existing = bins[key] {
            if cachedSampleRetentionPriority(sample) >= cachedSampleRetentionPriority(existing) {
                bins[key] = sample
            }
        } else {
            bins[key] = sample
        }
    }

    private static func reduceCachedSamplesIfNeeded(_ samples: [CachedCentroidSample],
                                                    targetCount: Int,
                                                    baseVoxelSize: Float) -> [CachedCentroidSample] {
        guard samples.count > targetCount else { return samples }

        var reduced = samples
        var voxelSize = max(baseVoxelSize * 1.15, 0.0009)
        while reduced.count > targetCount {
            var bins: [VoxelKey: CachedCentroidSample] = [:]
            bins.reserveCapacity(reduced.count)
            for sample in reduced {
                cacheSample(sample, into: &bins, voxelSize: voxelSize)
            }
            let nextReduced = Array(bins.values)
            if nextReduced.count == reduced.count {
                voxelSize *= 1.35
            } else {
                reduced = nextReduced
                voxelSize *= 1.15
            }
        }
        return reduced
    }

    private static func cachedSampleRetentionPriority(_ sample: CachedCentroidSample) -> Float {
        (sample.hsv.saturation * 1.6) + (sample.chroma * 1.2) + (sample.normalizedDominance * 0.9) + (sample.hsv.value * 0.15)
    }

    private static func interpolateVector3(weights: SIMD3<Float>,
                                           v0: SIMD3<Float>,
                                           v1: SIMD3<Float>,
                                           v2: SIMD3<Float>) -> SIMD3<Float> {
        (v0 * weights.x) + (v1 * weights.y) + (v2 * weights.z)
    }

    private static func interpolateVector2(weights: SIMD3<Float>,
                                           v0: SIMD2<Float>,
                                           v1: SIMD2<Float>,
                                           v2: SIMD2<Float>) -> SIMD2<Float> {
        (v0 * weights.x) + (v1 * weights.y) + (v2 * weights.z)
    }

    private static func colorMetrics(from rgb: SIMD3<Float>) -> ColorMetrics {
        let maximum = max(rgb.x, max(rgb.y, rgb.z))
        let minimum = min(rgb.x, min(rgb.y, rgb.z))
        let second = max(min(rgb.x, rgb.y), min(max(rgb.x, rgb.y), rgb.z))
        let chroma = maximum - minimum
        let normalizedDominance = maximum > 0 ? (maximum - second) / maximum : 0
        return ColorMetrics(
            maxComponent: maximum,
            minComponent: minimum,
            secondComponent: second,
            chroma: chroma,
            normalizedDominance: normalizedDominance,
            redDominance: rgb.x - max(rgb.y, rgb.z),
            blueDominance: rgb.z - max(rgb.x, rgb.y)
        )
    }

    private static func isStrongColorSeed(rgb: SIMD3<Float>, hsv: HSVColor, config: AnalysisConfig) -> Bool {
        let metrics = colorMetrics(from: rgb)
        guard hsv.saturation >= max(config.minSaturation * 0.7, 0.24),
              hsv.value >= max(config.minValue * 0.9, 0.12),
              metrics.chroma >= max(config.minChroma * 0.9, 0.09),
              metrics.normalizedDominance >= max(config.minDominance * 0.8, 0.08) else {
            return false
        }

        if config.blueHueRange.contains(hsv.hue),
           metrics.blueDominance >= max(config.minChroma * 0.35, 0.05) {
            return true
        }

        if config.redHueRanges.contains(where: { $0.contains(hsv.hue) }),
           metrics.redDominance >= max(config.minChroma * 0.35, 0.05) {
            return true
        }

        return false
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

    private static func logCachedSampleHSVDiagnostics(
        _ samples: [CachedCentroidSample],
        colorRichSamples: [CachedCentroidSample],
        config: AnalysisConfig
    ) {
        var hueHistogram = [Int](repeating: 0, count: 12)
        var saturationAtLeast005 = 0
        var saturationAtLeast010 = 0
        var valueAtLeast020 = 0
        var blueRuleCount = 0
        var redRuleCount = 0

        for sample in samples {
            let hue = sample.hsv.hue
            let saturation = sample.hsv.saturation
            let value = sample.hsv.value

            let normalizedHue = min(max(hue, 0), 359.999_9)
            let binIndex = min(11, Int(normalizedHue / 30))
            hueHistogram[binIndex] += 1

            if saturation >= 0.05 { saturationAtLeast005 += 1 }
            if saturation >= 0.10 { saturationAtLeast010 += 1 }
            if value >= 0.20 { valueAtLeast020 += 1 }

            switch classify(rgb: sample.rgb, hsv: sample.hsv, config: config) {
            case .blue:
                blueRuleCount += 1
            case .red:
                redRuleCount += 1
            case .other:
                break
            }
        }

        let histogramSummary = hueHistogram.enumerated()
            .map { index, count -> String in
                let start = index * 30
                let end = start + 30
                return "\(start)-\(end):\(count)"
            }
            .joined(separator: " ")

        print("[HSV.debug] cachedSamples=\(samples.count)")
        print("[HSV.debug] hueHistogram(12bins) \(histogramSummary)")
        print("[HSV.debug] sat>=0.05=\(saturationAtLeast005) sat>=0.10=\(saturationAtLeast010) val>=0.20=\(valueAtLeast020)")
        print("[HSV.debug] blueRule=\(blueRuleCount) redRule=\(redRuleCount)")

        let representativeSamples = representativeHSVDebugSamples(samples, maxCount: 20)
        for (index, sample) in representativeSamples.enumerated() {
            print(
                String(
                    format: "[HSV.sample %02d] h=%.1f s=%.3f v=%.3f rgb=(%.3f,%.3f,%.3f)",
                    index,
                    sample.hsv.hue,
                    sample.hsv.saturation,
                    sample.hsv.value,
                    sample.rgb.x,
                    sample.rgb.y,
                    sample.rgb.z
                )
            )
        }

        let colorRichCount = colorRichSamples.count
        print("[HSV.debug.colorRich] colorRichCount=\(colorRichCount)")

        guard colorRichCount > 0 else {
            print("[HSV.debug.colorRich] No strong-color seed samples")
            return
        }

        var colorRichHueHistogram = [Int](repeating: 0, count: 12)
        var colorRichBlueRuleCount = 0
        var colorRichRedRuleCount = 0

        for sample in colorRichSamples {
            let normalizedHue = min(max(sample.hsv.hue, 0), 359.999_9)
            let binIndex = min(11, Int(normalizedHue / 30))
            colorRichHueHistogram[binIndex] += 1

            switch classify(rgb: sample.rgb, hsv: sample.hsv, config: config) {
            case .blue:
                colorRichBlueRuleCount += 1
            case .red:
                colorRichRedRuleCount += 1
            case .other:
                break
            }
        }

        let colorRichHistogramSummary = colorRichHueHistogram.enumerated()
            .map { index, count -> String in
                let start = index * 30
                let end = start + 30
                return "\(start)-\(end):\(count)"
            }
            .joined(separator: " ")
        print("[HSV.debug.colorRich] hueHistogram(12bins) \(colorRichHistogramSummary)")
        print("[HSV.debug.colorRich] blueRule=\(colorRichBlueRuleCount) redRule=\(colorRichRedRuleCount)")
        let nearColorRichDiagnostics = nearColorRichDiagnostics(samples, colorRichSamples: colorRichSamples, config: config)
        print("[HSV.debug.nearColorRich] candidateNearColorRichCount=\(nearColorRichDiagnostics.candidateNearColorRichCount)")
        print("[HSV.debug.nearColorRich] blueRule=\(nearColorRichDiagnostics.blueRuleCount) redRule=\(nearColorRichDiagnostics.redRuleCount)")

        let representativeColorRichSamples = representativeHSVDebugSamples(colorRichSamples, maxCount: 20)
        for (index, sample) in representativeColorRichSamples.enumerated() {
            print(
                String(
                    format: "[HSV.colorRich.sample %02d] h=%.1f s=%.3f v=%.3f rgb=(%.3f,%.3f,%.3f)",
                    index,
                    sample.hsv.hue,
                    sample.hsv.saturation,
                    sample.hsv.value,
                    sample.rgb.x,
                    sample.rgb.y,
                    sample.rgb.z
                )
            )
        }
    }

    private static func classifySamples(
        _ samples: [CachedCentroidSample],
        config: AnalysisConfig
    ) -> (bluePoints: [SIMD3<Float>], redPoints: [SIMD3<Float>], candidateCount: Int, blueCount: Int, redCount: Int) {
        switch extractionMode {
        case .simpleThreshold:
            return classifySimpleThresholdSamples(samples, config: config)
        case .nearColorRich:
            return classifyNearColorRichSamples(samples, config: config)
        }
    }

    private static func classifySimpleThresholdSamples(
        _ samples: [CachedCentroidSample],
        config: AnalysisConfig
    ) -> (bluePoints: [SIMD3<Float>], redPoints: [SIMD3<Float>], candidateCount: Int, blueCount: Int, redCount: Int) {
        var bluePoints: [SIMD3<Float>] = []
        var redPoints: [SIMD3<Float>] = []

        for sample in samples {
            switch classify(rgb: sample.rgb, hsv: sample.hsv, config: config) {
            case .blue:
                bluePoints.append(sample.worldPosition.simd)
            case .red:
                redPoints.append(sample.worldPosition.simd)
            case .other:
                break
            }
        }

        return (bluePoints, redPoints, samples.count, bluePoints.count, redPoints.count)
    }

    private static func classifyNearColorRichSamples(
        _ samples: [CachedCentroidSample],
        config: AnalysisConfig
    ) -> (bluePoints: [SIMD3<Float>], redPoints: [SIMD3<Float>], candidateCount: Int, blueCount: Int, redCount: Int) {
        let colorRichSamples = samples.filter { isStrongColorSeed(rgb: $0.rgb, hsv: $0.hsv, config: config) }
        let diagnostics = nearColorRichDiagnostics(samples, colorRichSamples: colorRichSamples, config: config)
        var bluePoints: [SIMD3<Float>] = []
        var redPoints: [SIMD3<Float>] = []
        bluePoints.reserveCapacity(diagnostics.blueRuleCount)
        redPoints.reserveCapacity(diagnostics.redRuleCount)

        for (sample, isNearColorRich) in zip(samples, diagnostics.nearColorRichFlags) {
            guard isNearColorRich else { continue }
            switch classify(rgb: sample.rgb, hsv: sample.hsv, config: config) {
            case .blue:
                bluePoints.append(sample.worldPosition.simd)
            case .red:
                redPoints.append(sample.worldPosition.simd)
            case .other:
                break
            }
        }

        return (bluePoints, redPoints, diagnostics.candidateNearColorRichCount, diagnostics.blueRuleCount, diagnostics.redRuleCount)
    }

    private static func nearColorRichDiagnostics(
        _ samples: [CachedCentroidSample],
        colorRichSamples: [CachedCentroidSample],
        config: AnalysisConfig
    ) -> (nearColorRichFlags: [Bool], candidateNearColorRichCount: Int, blueRuleCount: Int, redRuleCount: Int) {
        _ = config
        guard !colorRichSamples.isEmpty else {
            return ([Bool](repeating: false, count: samples.count), 0, 0, 0)
        }

        let radius = nearColorRichRadiusMeters
        let neighborIndex = NeighborPointIndex(
            points: colorRichSamples.map { $0.worldPosition.simd },
            cellSize: max(radius, 0.001)
        )
        var nearColorRichFlags = [Bool](repeating: false, count: samples.count)
        var candidateNearColorRichCount = 0
        var blueRuleCount = 0
        var redRuleCount = 0

        for (index, sample) in samples.enumerated() {
            let samplePosition = sample.worldPosition.simd
            let isNearColorRich = neighborIndex.containsPoint(near: samplePosition, radius: radius)

            guard isNearColorRich else { continue }
            nearColorRichFlags[index] = true
            candidateNearColorRichCount += 1

            switch classify(rgb: sample.rgb, hsv: sample.hsv, config: config) {
            case .blue:
                blueRuleCount += 1
            case .red:
                redRuleCount += 1
            case .other:
                break
            }
        }

        return (nearColorRichFlags, candidateNearColorRichCount, blueRuleCount, redRuleCount)
    }

    private static func representativeHSVDebugSamples(
        _ samples: [CachedCentroidSample],
        maxCount: Int
    ) -> [CachedCentroidSample] {
        guard !samples.isEmpty, maxCount > 0 else { return [] }
        guard samples.count > maxCount else { return samples }

        var chosenIndices: [Int] = []
        chosenIndices.reserveCapacity(maxCount)
        let denominator = max(maxCount - 1, 1)
        let upperBound = samples.count - 1

        for i in 0..<maxCount {
            let raw = (i * upperBound) / denominator
            let index = min(upperBound, max(0, raw))
            if chosenIndices.last != index {
                chosenIndices.append(index)
            }
        }

        return chosenIndices.map { samples[$0] }
    }

    private static func collectGeometryNodes(from node: SCNNode, into storage: inout [SCNNode]) {
        if node.geometry != nil {
            storage.append(node)
        }

        for child in node.childNodes {
            collectGeometryNodes(from: child, into: &storage)
        }
    }

    private static func classify(rgb: SIMD3<Float>, hsv: HSVColor, config: AnalysisConfig) -> MaskColor {
        let metrics = colorMetrics(from: rgb)
        guard hsv.saturation >= config.minSaturation,
              hsv.value >= config.minValue,
              metrics.chroma >= config.minChroma,
              metrics.normalizedDominance >= config.minDominance else {
            return .other
        }

        if config.blueHueRange.contains(hsv.hue),
           metrics.blueDominance >= max(config.minChroma * 0.40, 0.05) {
            return .blue
        }

        if config.redHueRanges.contains(where: { $0.contains(hsv.hue) }),
           metrics.redDominance >= max(config.minChroma * 0.40, 0.05) {
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
