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
        if let bounds = combinedBounds(sceneBounds(rootNode: newContainer), sceneBounds(rootNode: usedContainer)) {
            let camera = makeFramingCamera(bounds: bounds)
            overlayScene.rootNode.addChildNode(camera)
        }

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
        // ROI可視化を優先するため、メッシュは薄く表示してAABBと点群を見やすくする。
        applyOpacityRecursively(node: rawContainer, opacity: 0.2)
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
            scene.rootNode.addChildNode(aabbWireframeNode(bounds: appliedROI, color: .systemGreen))
        }
        if let pendingROI {
            scene.rootNode.addChildNode(aabbWireframeNode(bounds: pendingROI, color: .systemOrange))
        }

        addAxisGuide(to: scene.rootNode)
        let focusBounds = pendingROI ?? appliedROI ?? package.sourceBounds
        scene.rootNode.addChildNode(makeFramingCamera(bounds: focusBounds))
        return scene
    }

    static func makeFramingCamera(bounds: SpatialBounds3D) -> SCNNode {
        let cameraNode = SCNNode()
        let camera = SCNCamera()
        camera.zNear = 0.0001
        camera.zFar = 100
        camera.fieldOfView = 50
        cameraNode.camera = camera

        let center = SIMD3<Float>(
            (bounds.min.x + bounds.max.x) * 0.5,
            (bounds.min.y + bounds.max.y) * 0.5,
            (bounds.min.z + bounds.max.z) * 0.5
        )
        let extent = SIMD3<Float>(
            max(bounds.max.x - bounds.min.x, 0.0001),
            max(bounds.max.y - bounds.min.y, 0.0001),
            max(bounds.max.z - bounds.min.z, 0.0001)
        )
        let maxExtent = max(extent.x, max(extent.y, extent.z))
        let distance = maxExtent * 2.8
        cameraNode.simdPosition = center + SIMD3<Float>(distance, distance * 0.85, distance)
        cameraNode.look(at: SCNVector3(center.x, center.y, center.z))
        return cameraNode
    }

    static func aabbWireframeNode(bounds: SpatialBounds3D,
                                  color: UIColor,
                                  radius: CGFloat = 0.00045) -> SCNNode {
        let corners = [
            SIMD3<Float>(bounds.min.x, bounds.min.y, bounds.min.z),
            SIMD3<Float>(bounds.max.x, bounds.min.y, bounds.min.z),
            SIMD3<Float>(bounds.max.x, bounds.max.y, bounds.min.z),
            SIMD3<Float>(bounds.min.x, bounds.max.y, bounds.min.z),
            SIMD3<Float>(bounds.min.x, bounds.min.y, bounds.max.z),
            SIMD3<Float>(bounds.max.x, bounds.min.y, bounds.max.z),
            SIMD3<Float>(bounds.max.x, bounds.max.y, bounds.max.z),
            SIMD3<Float>(bounds.min.x, bounds.max.y, bounds.max.z)
        ]
        let edges: [(Int, Int)] = [
            (0, 1), (1, 2), (2, 3), (3, 0),
            (4, 5), (5, 6), (6, 7), (7, 4),
            (0, 4), (1, 5), (2, 6), (3, 7)
        ]

        let root = SCNNode()
        for (a, b) in edges {
            let start = corners[a]
            let end = corners[b]
            root.addChildNode(lineNode(start: start, end: end, radius: radius, color: color))
        }
        return root
    }

    static func combinedBounds(_ bounds: SpatialBounds3D?...) -> SpatialBounds3D? {
        combinedBounds(bounds)
    }

    static func combinedBounds(_ bounds: [SpatialBounds3D?]) -> SpatialBounds3D? {
        let valid = bounds.compactMap { $0 }
        guard let first = valid.first else { return nil }

        var minX = first.min.x
        var minY = first.min.y
        var minZ = first.min.z
        var maxX = first.max.x
        var maxY = first.max.y
        var maxZ = first.max.z

        for b in valid.dropFirst() {
            minX = min(minX, b.min.x); minY = min(minY, b.min.y); minZ = min(minZ, b.min.z)
            maxX = max(maxX, b.max.x); maxY = max(maxY, b.max.y); maxZ = max(maxZ, b.max.z)
        }
        return SpatialBounds3D(min: Point3(x: minX, y: minY, z: minZ),
                               max: Point3(x: maxX, y: maxY, z: maxZ))
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

    private static func lineNode(start: SIMD3<Float>,
                                 end: SIMD3<Float>,
                                 radius: CGFloat,
                                 color: UIColor) -> SCNNode {
        let vector = end - start
        let length = simd_length(vector)
        let cylinder = SCNCylinder(radius: radius, height: CGFloat(max(length, 0.0001)))
        cylinder.radialSegmentCount = 8
        cylinder.firstMaterial?.diffuse.contents = color
        cylinder.firstMaterial?.emission.contents = color.withAlphaComponent(0.3)
        cylinder.firstMaterial?.lightingModel = .constant

        let node = SCNNode(geometry: cylinder)
        let mid = (start + end) * 0.5
        node.simdPosition = mid
        node.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: simd_normalize(vector))
        return node
    }

    private static func sceneBounds(rootNode: SCNNode) -> SpatialBounds3D? {
        var points: [SIMD3<Float>] = []
        collectBoundsPoints(node: rootNode, into: &points)
        return SpatialBounds3D(points: points)
    }

    private static func collectBoundsPoints(node: SCNNode, into points: inout [SIMD3<Float>]) {
        if let geometry = node.geometry {
            let (minVec, maxVec) = geometry.boundingBox
            let corners = [
                SIMD3<Float>(minVec.x, minVec.y, minVec.z),
                SIMD3<Float>(maxVec.x, minVec.y, minVec.z),
                SIMD3<Float>(minVec.x, maxVec.y, minVec.z),
                SIMD3<Float>(maxVec.x, maxVec.y, minVec.z),
                SIMD3<Float>(minVec.x, minVec.y, maxVec.z),
                SIMD3<Float>(maxVec.x, minVec.y, maxVec.z),
                SIMD3<Float>(minVec.x, maxVec.y, maxVec.z),
                SIMD3<Float>(maxVec.x, maxVec.y, maxVec.z)
            ]
            for corner in corners {
                points.append(node.simdConvertPosition(corner, to: nil))
            }
        }
        for child in node.childNodes {
            collectBoundsPoints(node: child, into: &points)
        }
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
