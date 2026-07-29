import ARKit
import SceneKit
import UIKit

/// Renders a lightweight capture preview from sampled LiDAR vertices. Points
/// keep the camera readable; unlike mesh faces, they cannot blanket objects.
enum FogRevealRenderer {
    static let meshRenderingOrder = 0
    private static let maximumPointsPerAnchor = 1_500

    static func samplingStride(vertexCount: Int) -> Int {
        max(1, vertexCount / maximumPointsPerAnchor)
    }

    /// Builds a bounded point preview for one mesh anchor. `confidences` is
    /// resolved by the caller so the voxel-grid lock only covers dictionary reads.
    static func makeGeometry(from meshGeometry: ARMeshGeometry, confidences: [Float], visible: [Bool]? = nil) -> SCNGeometry {
        let vertices = meshGeometry.vertices
        let stride = samplingStride(vertexCount: vertices.count)
        let baseAddress = vertices.buffer.contents()

        var positions = [SIMD3<Float>]()
        var colors = [SCNVector4]()
        positions.reserveCapacity(maximumPointsPerAnchor)
        colors.reserveCapacity(maximumPointsPerAnchor)
        for index in Swift.stride(from: 0, to: vertices.count, by: stride) {
            guard visible?[index] ?? true else { continue }
            let confidence = index < confidences.count ? confidences[index] : 0
            let alpha = ScanPreviewStyle.opacity(for: confidence)
            guard alpha > 0 else { continue }
            let pointer = baseAddress.advanced(by: vertices.offset + vertices.stride * index)
            positions.append(pointer.assumingMemoryBound(to: SIMD3<Float>.self).pointee)
            colors.append(SCNVector4(1, 0.05, 0.05, alpha))
        }

        guard !positions.isEmpty else { return SCNGeometry() }

        let vertexData = Data(bytes: positions, count: positions.count * MemoryLayout<SIMD3<Float>>.stride)
        let vertexSource = SCNGeometrySource(
            data: vertexData,
            semantic: .vertex,
            vectorCount: positions.count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD3<Float>>.stride
        )

        let colorData = Data(bytes: colors, count: colors.count * MemoryLayout<SCNVector4>.stride)
        let colorSource = SCNGeometrySource(
            data: colorData,
            semantic: .color,
            vectorCount: colors.count,
            usesFloatComponents: true,
            componentsPerVector: 4,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SCNVector4>.stride
        )

        let element = SCNGeometryElement(
            data: nil,
            primitiveType: .point,
            primitiveCount: positions.count,
            bytesPerIndex: 0
        )
        element.pointSize = 0.035
        element.minimumPointScreenSpaceRadius = 2
        element.maximumPointScreenSpaceRadius = 8

        let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])

        let material = SCNMaterial()
        material.diffuse.contents = UIColor.red
        material.lightingModel = .constant
        material.blendMode = .alpha
        material.readsFromDepthBuffer = true
        material.writesToDepthBuffer = false
        geometry.materials = [material]

        return geometry
    }
}
