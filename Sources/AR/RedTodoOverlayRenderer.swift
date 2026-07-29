import SceneKit
import UIKit

final class RedTodoOverlayRenderer {
    static let maxVisibleNodes = 800
    static let maxAddsPerUpdate = 150
    static let maxRemovesPerUpdate = 300

    let rootNode = SCNNode()
    private var nodesByCoordinate: [VoxelCoordinate: SCNNode] = [:]

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
        let geometry = SCNBox(width: 0.09, height: 0.09, length: 0.09, chamferRadius: 0.005)
        let material = SCNMaterial()
        material.diffuse.contents = UIColor(red: 1.0, green: 0.05, blue: 0.05, alpha: 0.45)
        material.lightingModel = .constant
        material.blendMode = .alpha
        geometry.materials = [material]

        let node = SCNNode(geometry: geometry)
        node.simdPosition = center
        return node
    }
}
