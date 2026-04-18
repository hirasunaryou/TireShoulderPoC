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

        return overlayScene
    }

    static func makeInspectorScene(modelURL: URL,
                                   package: LoadedModelPackage,
                                   showBlue: Bool,
                                   showRed: Bool) throws -> SCNScene {
        let rawScene: SCNScene
        do {
            rawScene = try SCNScene(url: modelURL, options: nil)
        } catch {
            throw PoCError.sceneLoadFailed(error.localizedDescription)
        }

        let scene = SCNScene()
        let rawContainer = SCNNode()
        cloneChildren(from: rawScene.rootNode, to: rawContainer)
        scene.rootNode.addChildNode(rawContainer)

        if showBlue {
            scene.rootNode.addChildNode(pointCloudNode(points: package.bluePoints.map(\.simd), color: .systemBlue))
        }
        if showRed {
            scene.rootNode.addChildNode(pointCloudNode(points: package.redPoints.map(\.simd), color: .systemRed))
        }

        addAxisGuide(to: scene.rootNode)
        return scene
    }

    private static func pointCloudNode(points: [SIMD3<Float>], color: UIColor) -> SCNNode {
        let node = SCNNode()
        let pointRadius: CGFloat = 0.0006

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
