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
        overlayScene.rootNode.addChildNode(cameraNode)
        overlayScene.pointOfView = cameraNode

        return overlayScene
    }

    static func makeInspectorScene(modelURL: URL,
                                   package: LoadedModelPackage,
                                   showBlue: Bool,
                                   showRed: Bool,
                                   pendingROI: SpatialBounds3D? = nil,
                                   appliedROI: SpatialBounds3D? = nil) throws -> SCNScene {
        let rawScene: SCNScene
        do {
            rawScene = try SCNScene(url: modelURL, options: nil)
        } catch {
            throw PoCError.sceneLoadFailed(error.localizedDescription)
        }

        let scene = SCNScene()
        let rawContainer = SCNNode()
        cloneChildren(from: rawScene.rootNode, to: rawContainer)
        let roiVisualizationEnabled = pendingROI != nil || appliedROI != nil
        if roiVisualizationEnabled {
            // ROI可視化時は「全体メッシュ」を少し薄くして、ROI関連ノードを見つけやすくする。
            applyOpacityRecursively(node: rawContainer, opacity: 0.30)
        }
        scene.rootNode.addChildNode(rawContainer)

        scene.rootNode.addChildNode(
            pointCloudNode(
                points: package.sampledPoints.map(\.simd),
                color: .lightGray,
                pointRadius: 0.0002
            )
        )
        scene.rootNode.addChildNode(
            pointCloudNode(
                points: package.colorRichPoints.map(\.simd),
                color: .systemYellow,
                pointRadius: 0.00024
            )
        )

        if showBlue {
            scene.rootNode.addChildNode(pointCloudNode(points: package.bluePoints.map(\.simd), color: .systemBlue))
        }
        if showRed {
            scene.rootNode.addChildNode(pointCloudNode(points: package.redPoints.map(\.simd), color: .systemRed))
        }

        if let appliedROI {
            let appliedNode = aabbWireframeNode(bounds: appliedROI, color: .systemGreen, thickness: 0.00045)
            appliedNode.name = "AppliedROI"
            scene.rootNode.addChildNode(appliedNode)
        }
        if let pendingROI {
            let pendingNode = aabbWireframeNode(bounds: pendingROI, color: .systemOrange, thickness: 0.00034)
            pendingNode.name = "PendingROI"
            pendingNode.opacity = 0.90
            scene.rootNode.addChildNode(pendingNode)
        }

        addAxisGuide(to: scene.rootNode)
        let focusBounds = pendingROI ?? appliedROI ?? package.sourceBounds
        let framingBounds = combinedBounds([package.sourceBounds, focusBounds]) ?? package.sourceBounds
        let cameraNode = makeFramingCamera(bounds: framingBounds)
        scene.rootNode.addChildNode(cameraNode)
        scene.pointOfView = cameraNode
        return scene
    }

    static func makeFramingCamera(bounds: SpatialBounds3D) -> SCNNode {
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
        let distance = radius * 2.4
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
        var minVector = SCNVector3Zero
        var maxVector = SCNVector3Zero
        let hasBounds = node.getBoundingBoxMin(&minVector, max: &maxVector)
        guard hasBounds else { return nil }

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
