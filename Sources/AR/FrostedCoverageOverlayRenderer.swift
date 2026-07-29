import SceneKit
import UIKit

final class FrostedCoverageOverlayRenderer {
    static let maxVisibleNodes = 600
    static let maxAddsPerUpdate = 120
    static let maxRemovesPerUpdate = 240

    let rootNode = SCNNode()
    private var nodesByCoordinate: [VoxelCoordinate: SCNNode] = [:]
    private let material: SCNMaterial = {
        let material = SCNMaterial()
        material.diffuse.contents = UIColor(white: 0.86, alpha: 0.34)
        material.emission.contents = UIColor(white: 0.55, alpha: 0.18)
        material.lightingModel = .constant
        material.blendMode = .alpha
        material.isDoubleSided = true
        material.writesToDepthBuffer = false
        return material
    }()

    func update(samples: [VoxelOverlaySample]) {
        let capped = Array(samples.prefix(Self.maxVisibleNodes))
        let wanted = Set(capped.map(\.coordinate))

        var removed = 0
        for coordinate in nodesByCoordinate.keys where !wanted.contains(coordinate) {
            guard removed < Self.maxRemovesPerUpdate else { break }
            nodesByCoordinate.removeValue(forKey: coordinate)?.removeFromParentNode()
            removed += 1
        }

        var added = 0
        for sample in capped where nodesByCoordinate[sample.coordinate] == nil {
            guard added < Self.maxAddsPerUpdate else { break }
            let node = makeNode(at: sample.center)
            nodesByCoordinate[sample.coordinate] = node
            rootNode.addChildNode(node)
            added += 1
        }
    }

    private func makeNode(at center: SIMD3<Float>) -> SCNNode {
        let geometry = SCNBox(width: 0.12, height: 0.12, length: 0.12, chamferRadius: 0.02)
        geometry.materials = [material]

        let node = SCNNode(geometry: geometry)
        node.simdPosition = center
        node.opacity = 0.85
        return node
    }
}
