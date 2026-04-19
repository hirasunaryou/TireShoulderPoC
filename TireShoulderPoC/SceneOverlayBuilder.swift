import Foundation
import SceneKit
import UIKit
import simd

enum SceneOverlayBuilder {
    static func makeOverlayScene(newURL: URL,
                                 usedURL: URL,
                                 usedToNew: Transform4x4) throws -> SCNScene {
        let newScene: SCNScene
        let usedScene: SCNScene

        do {
            newScene = try SCNScene(url: newURL, options: nil)
            usedScene = try SCNScene(url: usedURL, options: nil)
        } catch {
            throw PoCError.sceneLoadFailed(error.localizedDescription)
        }

        let overlayScene = SCNScene()

        let newContainer = SCNNode()
        cloneChildren(from: newScene.rootNode, to: newContainer)
        applyOpacityRecursively(node: newContainer, opacity: 0.95)

        let usedContainer = SCNNode()
        cloneChildren(from: usedScene.rootNode, to: usedContainer)
        usedContainer.simdTransform = usedToNew.simd
        applyOpacityRecursively(node: usedContainer, opacity: 0.55)

        overlayScene.rootNode.addChildNode(newContainer)
        overlayScene.rootNode.addChildNode(usedContainer)

        addAxisGuide(to: overlayScene.rootNode)
        let sceneBounds = combinedBounds([bounds(for: newContainer), bounds(for: usedContainer)]) ??
            SpatialBounds3D(min: Point3(x: -0.05, y: -0.05, z: -0.05), max: Point3(x: 0.05, y: 0.05, z: 0.05))
        let cameraNode = makeFramingCamera(bounds: sceneBounds)
        cameraNode.name = "DefaultCamera"
        overlayScene.rootNode.addChildNode(cameraNode)

        return overlayScene
    }

    static func makeInspectorScene(modelURL: URL,
                                   package: LoadedModelPackage,
                                   options: InspectorSceneOptions) throws -> SCNScene {
        let rawScene: SCNScene
        do {
            rawScene = try SCNScene(url: modelURL, options: nil)
        } catch {
            throw PoCError.sceneLoadFailed(error.localizedDescription)
        }

        let scene = SCNScene()
        scene.background.contents = UIColor(white: 0.07, alpha: 1.0)
        let rawContainer = SCNNode()
        rawContainer.name = "InspectableMeshRoot"
        cloneChildren(from: rawScene.rootNode, to: rawContainer)
        // モードごとに「元メッシュ」と「点群」の主役を切り替える。
        let meshOpacity: CGFloat
        switch options.renderMode {
        case .texturedMesh:
            meshOpacity = 0.95
        case .sampledRGB:
            meshOpacity = 0.18
        case .maskLocator:
            meshOpacity = 0.36
        }
        applyOpacityRecursively(node: rawContainer, opacity: meshOpacity)
        scene.rootNode.addChildNode(rawContainer)

        if options.renderMode == .sampledRGB {
            // 解析に使う cachedSamples.rgb をそのまま可視化。
            scene.rootNode.addChildNode(
                coloredPointCloudNode(
                    samples: package.cachedSamples,
                    pointRadius: 0.00035
                )
            )
        } else {
            if options.showSampledPoints {
                scene.rootNode.addChildNode(
                    pointCloudNode(
                        points: package.sampledPoints.map(\.simd),
                        color: .lightGray,
                        pointRadius: 0.0002
                    )
                )
            }
            if options.showColorRichPoints || options.renderMode == .maskLocator {
                scene.rootNode.addChildNode(
                    pointCloudNode(
                        points: package.colorRichPoints.map(\.simd),
                        color: .systemYellow,
                        pointRadius: options.renderMode == .maskLocator ? 0.00038 : 0.00024
                    )
                )
            }
        }

        if options.showBlue {
            scene.rootNode.addChildNode(
                pointCloudNode(
                    points: package.bluePoints.map(\.simd),
                    color: .systemBlue,
                    pointRadius: options.renderMode == .maskLocator ? 0.0007 : 0.0006
                )
            )
        }
        if options.showRed {
            scene.rootNode.addChildNode(
                pointCloudNode(
                    points: package.redPoints.map(\.simd),
                    color: .systemRed,
                    pointRadius: options.renderMode == .maskLocator ? 0.0007 : 0.0006
                )
            )
        }

        if options.showROIBounds {
            if let appliedROI = options.appliedROI {
                let appliedNode = aabbWireframeNode(bounds: appliedROI, color: .systemGreen, thickness: 0.00045)
                appliedNode.name = "AppliedROI"
                scene.rootNode.addChildNode(appliedNode)
            }
            if let pendingROI = options.pendingROI {
                let pendingNode = aabbWireframeNode(bounds: pendingROI, color: .systemOrange, thickness: 0.00034)
                pendingNode.name = "PendingROI"
                pendingNode.opacity = 0.90
                scene.rootNode.addChildNode(pendingNode)
            }
            if let brushAutoROI = options.brushAutoROI {
                let brushROINode = aabbWireframeNode(bounds: brushAutoROI, color: .cyan, thickness: 0.00052)
                brushROINode.name = "BrushAutoROI"
                scene.rootNode.addChildNode(brushROINode)
            }
        }

        if !options.selectedBrushPoints.isEmpty {
            scene.rootNode.addChildNode(
                pointCloudNode(
                    points: options.selectedBrushPoints.map(\.simd),
                    color: .cyan,
                    pointRadius: 0.0011
                )
            )
        }
        if let recentBrushStamp = options.recentBrushStamp {
            let recentNode = SCNNode(geometry: SCNSphere(radius: CGFloat(max(recentBrushStamp.radiusMeters * 0.65, 0.0012))))
            recentNode.simdPosition = recentBrushStamp.center.simd
            recentNode.geometry?.firstMaterial?.diffuse.contents = UIColor.systemMint
            recentNode.geometry?.firstMaterial?.lightingModel = .constant
            recentNode.geometry?.firstMaterial?.emission.contents = UIColor.white
            recentNode.opacity = 0.92
            recentNode.name = "RecentBrushStamp"
            scene.rootNode.addChildNode(recentNode)
        }

        if options.renderMode == .maskLocator {
            if let colorRichBounds = SpatialBounds3D(points: package.colorRichPoints.map(\.simd)) {
                scene.rootNode.addChildNode(aabbWireframeNode(bounds: colorRichBounds, color: .systemYellow, thickness: 0.00038))
            }
            if options.showBlue, let blueBounds = SpatialBounds3D(points: package.bluePoints.map(\.simd)) {
                scene.rootNode.addChildNode(aabbWireframeNode(bounds: blueBounds, color: .systemBlue, thickness: 0.00038))
            }
            if options.showRed, let redBounds = SpatialBounds3D(points: package.redPoints.map(\.simd)) {
                scene.rootNode.addChildNode(aabbWireframeNode(bounds: redBounds, color: .systemRed, thickness: 0.00038))
            }
        }

        addAxisGuide(to: scene.rootNode)
        // 寄り先フォーカス対象が空の場合は ROI / model 全体にフォールバックする。
        let focusBounds = makeFocusBounds(
            focusMode: options.focusMode,
            package: package,
            pendingROI: options.pendingROI,
            appliedROI: options.appliedROI
        ) ?? options.pendingROI ?? options.appliedROI ?? package.sourceBounds
        let framingBounds = focusBounds
        let cameraNode = makeFramingCamera(bounds: framingBounds, distanceScale: options.framingDistanceScale)
        cameraNode.name = "InspectorCamera"
        scene.rootNode.addChildNode(cameraNode)
        return scene
    }

    static func makeFramingCamera(bounds: SpatialBounds3D, distanceScale: Float = 1.0) -> SCNNode {
        let camera = SCNCamera()
        camera.zNear = 0.0001
        camera.zFar = 200
        camera.fieldOfView = 50

        let center = SIMD3<Float>(
            (bounds.min.x + bounds.max.x) * 0.5,
            (bounds.min.y + bounds.max.y) * 0.5,
            (bounds.min.z + bounds.max.z) * 0.5
        )
        let size = SIMD3<Float>(
            bounds.max.x - bounds.min.x,
            bounds.max.y - bounds.min.y,
            bounds.max.z - bounds.min.z
        )
        let radius = max(max(size.x, size.y), max(size.z, 0.0005))
        let distance = radius * 2.4 * max(distanceScale, 0.2)
        let position = SIMD3<Float>(
            center.x + distance * 0.85,
            center.y + distance * 0.65,
            center.z + distance
        )

        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.simdPosition = position
        cameraNode.simdLook(at: center)
        return cameraNode
    }

    static func aabbWireframeNode(bounds: SpatialBounds3D,
                                  color: UIColor = .systemOrange,
                                  thickness: CGFloat = 0.00035) -> SCNNode {
        let min = bounds.min
        let max = bounds.max

        let p0 = SIMD3<Float>(min.x, min.y, min.z)
        let p1 = SIMD3<Float>(max.x, min.y, min.z)
        let p2 = SIMD3<Float>(max.x, max.y, min.z)
        let p3 = SIMD3<Float>(min.x, max.y, min.z)
        let p4 = SIMD3<Float>(min.x, min.y, max.z)
        let p5 = SIMD3<Float>(max.x, min.y, max.z)
        let p6 = SIMD3<Float>(max.x, max.y, max.z)
        let p7 = SIMD3<Float>(min.x, max.y, max.z)

        let edges: [(SIMD3<Float>, SIMD3<Float>)] = [
            (p0, p1), (p1, p2), (p2, p3), (p3, p0),
            (p4, p5), (p5, p6), (p6, p7), (p7, p4),
            (p0, p4), (p1, p5), (p2, p6), (p3, p7)
        ]
        let root = SCNNode()
        for (start, end) in edges {
            root.addChildNode(lineNode(from: start, to: end, color: color, thickness: thickness))
        }
        return root
    }

    static func combinedBounds(_ boundsList: [SpatialBounds3D?]) -> SpatialBounds3D? {
        let valid = boundsList.compactMap { $0 }
        guard let first = valid.first else { return nil }

        var minX = first.min.x
        var minY = first.min.y
        var minZ = first.min.z
        var maxX = first.max.x
        var maxY = first.max.y
        var maxZ = first.max.z

        for bounds in valid.dropFirst() {
            minX = Swift.min(minX, bounds.min.x)
            minY = Swift.min(minY, bounds.min.y)
            minZ = Swift.min(minZ, bounds.min.z)
            maxX = Swift.max(maxX, bounds.max.x)
            maxY = Swift.max(maxY, bounds.max.y)
            maxZ = Swift.max(maxZ, bounds.max.z)
        }

        return SpatialBounds3D(
            min: Point3(x: minX, y: minY, z: minZ),
            max: Point3(x: maxX, y: maxY, z: maxZ)
        )
    }

    private static func pointCloudNode(points: [SIMD3<Float>],
                                       color: UIColor,
                                       pointRadius: CGFloat = 0.0006) -> SCNNode {
        let node = SCNNode()

        // PoC用途のため、描画コストより視認性を優先してシンプルな球メッシュで表示する。
        let sphere = SCNSphere(radius: pointRadius)
        sphere.segmentCount = 8
        sphere.firstMaterial?.diffuse.contents = color
        sphere.firstMaterial?.lightingModel = .constant

        for point in points {
            let pointNode = SCNNode(geometry: sphere)
            pointNode.simdPosition = point
            node.addChildNode(pointNode)
        }
        return node
    }

    private static func coloredPointCloudNode(samples: [CachedCentroidSample],
                                              pointRadius: CGFloat = 0.00035) -> SCNNode {
        let root = SCNNode()
        for sample in samples {
            let sphere = SCNSphere(radius: pointRadius)
            sphere.segmentCount = 8
            sphere.firstMaterial?.diffuse.contents = color(fromRGB: sample.rgb)
            sphere.firstMaterial?.lightingModel = .constant

            let pointNode = SCNNode(geometry: sphere)
            pointNode.simdPosition = sample.worldPosition.simd
            root.addChildNode(pointNode)
        }
        return root
    }

    private static func color(fromRGB rgb: SIMD3<Float>) -> UIColor {
        UIColor(
            red: CGFloat(max(0, min(1, rgb.x))),
            green: CGFloat(max(0, min(1, rgb.y))),
            blue: CGFloat(max(0, min(1, rgb.z))),
            alpha: 1
        )
    }

    private static func makeFocusBounds(focusMode: InspectorFocusMode,
                                        package: LoadedModelPackage,
                                        pendingROI: SpatialBounds3D?,
                                        appliedROI: SpatialBounds3D?) -> SpatialBounds3D? {
        switch focusMode {
        case .model:
            return package.sourceBounds
        case .roi:
            return pendingROI ?? appliedROI
        case .colorRich:
            return SpatialBounds3D(points: package.colorRichPoints.map(\.simd))
        case .blue:
            return SpatialBounds3D(points: package.bluePoints.map(\.simd))
        case .red:
            return SpatialBounds3D(points: package.redPoints.map(\.simd))
        }
    }

    private static func cloneChildren(from root: SCNNode, to destination: SCNNode) {
        for child in root.childNodes {
            destination.addChildNode(child.clone())
        }
    }

    private static func applyOpacityRecursively(node: SCNNode, opacity: CGFloat) {
        node.opacity = opacity
        if let geometry = node.geometry {
            geometry.materials.forEach { material in
                material.transparency = opacity
                material.isDoubleSided = true
            }
        }
        node.childNodes.forEach { applyOpacityRecursively(node: $0, opacity: opacity) }
    }

    private static func bounds(for node: SCNNode) -> SpatialBounds3D? {
        let (minVector, maxVector) = node.boundingBox
        guard minVector.x.isFinite, minVector.y.isFinite, minVector.z.isFinite,
              maxVector.x.isFinite, maxVector.y.isFinite, maxVector.z.isFinite else {
            return nil
        }

        let minWorld = node.convertPosition(minVector, to: nil)
        let maxWorld = node.convertPosition(maxVector, to: nil)
        return SpatialBounds3D(
            min: Point3(x: min(minWorld.x, maxWorld.x), y: min(minWorld.y, maxWorld.y), z: min(minWorld.z, maxWorld.z)),
            max: Point3(x: max(minWorld.x, maxWorld.x), y: max(minWorld.y, maxWorld.y), z: max(minWorld.z, maxWorld.z))
        )
    }

    private static func lineNode(from start: SIMD3<Float>,
                                 to end: SIMD3<Float>,
                                 color: UIColor,
                                 thickness: CGFloat) -> SCNNode {
        let vector = end - start
        let length = simd_length(vector)
        let safeLength = max(length, 0.00001)

        let cylinder = SCNCylinder(radius: thickness, height: CGFloat(safeLength))
        cylinder.radialSegmentCount = 8
        cylinder.firstMaterial?.diffuse.contents = color
        cylinder.firstMaterial?.lightingModel = .constant

        let node = SCNNode(geometry: cylinder)
        let midpoint = (start + end) * 0.5
        node.simdPosition = midpoint

        let from = SIMD3<Float>(0, 1, 0)
        let direction = simd_normalize(vector)
        let dot = simd_dot(from, direction)
        if abs(dot + 1) < 0.00001 {
            node.simdOrientation = simd_quatf(angle: .pi, axis: SIMD3<Float>(1, 0, 0))
        } else if abs(dot - 1) > 0.00001 {
            let axis = simd_normalize(simd_cross(from, direction))
            let angle = acos(max(-1, min(1, dot)))
            node.simdOrientation = simd_quatf(angle: angle, axis: axis)
        }

        return node
    }

    private static func addAxisGuide(to rootNode: SCNNode) {
        let length: CGFloat = 0.03
        let radius: CGFloat = 0.0008

        let xNode = axisNode(length: length, radius: radius)
        xNode.eulerAngles = SCNVector3(0, 0, -Float.pi / 2)
        xNode.position = SCNVector3(Float(length / 2), 0, 0)

        let yNode = axisNode(length: length, radius: radius)
        yNode.position = SCNVector3(0, Float(length / 2), 0)

        let zNode = axisNode(length: length, radius: radius)
        zNode.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
        zNode.position = SCNVector3(0, 0, Float(length / 2))

        rootNode.addChildNode(xNode)
        rootNode.addChildNode(yNode)
        rootNode.addChildNode(zNode)
    }

    private static func axisNode(length: CGFloat, radius: CGFloat) -> SCNNode {
        let geometry = SCNCylinder(radius: radius, height: length)
        geometry.radialSegmentCount = 12
        geometry.firstMaterial?.diffuse.contents = UIColor.white.withAlphaComponent(0.75)
        return SCNNode(geometry: geometry)
    }
}
