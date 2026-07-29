import ARKit
import SceneKit
import UIKit

/// Renders the Scaniverse-style capture illusion: the whole scene reads as
/// fogged, and the real camera image is revealed gradually per-surface as scan
/// confidence rises.
///
/// Two cooperating layers, both plain SceneKit — no custom shaders:
///
/// 1. A large plane parented to the camera, sitting just beyond scanning range.
///    It fills the view for free and provides the default fogged state wherever
///    LiDAR has not reached yet.
/// 2. The real LiDAR mesh, drawn in the same fog colour with a per-vertex alpha
///    of `1 - confidence`, and writing to the depth buffer. Because it is nearer
///    than the plane, the plane's fragments fail the depth test wherever mesh
///    exists — so meshed regions are governed solely by their own alpha, with no
///    seam and no double-darkening where the two would otherwise overlap.
enum FogRevealRenderer {
    /// Shared by both layers. They must match exactly or the mesh edges show as
    /// a visible seam against the plane.
    static let fogWhite: CGFloat = 0.86
    static let fogAlpha: CGFloat = 0.97

    /// Just beyond `CoverageClassifier.maxValidDistance` (3.0m), so the plane
    /// never sits in front of a surface close enough to actually be scanned.
    static let fogPlaneDistance: Float = 3.2

    /// Generously larger than the camera frustum at `fogPlaneDistance`, so the
    /// plane always fills the view without per-frame resizing. Two triangles —
    /// the size costs nothing.
    static let fogPlaneSize: CGFloat = 40

    /// Mesh draws before the plane so its depth writes are already in place when
    /// the plane's fragments are depth-tested.
    static let meshRenderingOrder = 0
    static let fogPlaneRenderingOrder = 100

    static var fogColor: UIColor {
        UIColor(white: fogWhite, alpha: fogAlpha)
    }

    /// The camera-parented plane providing the default fogged state.
    static func makeFogPlaneNode() -> SCNNode {
        let plane = SCNPlane(width: fogPlaneSize, height: fogPlaneSize)

        let material = SCNMaterial()
        material.diffuse.contents = fogColor
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.blendMode = .alpha
        // Reads depth so the mesh can occlude it; writes none of its own, or it
        // would occlude the mesh drawn after it in later frames.
        material.readsFromDepthBuffer = true
        material.writesToDepthBuffer = false
        plane.materials = [material]

        let node = SCNNode(geometry: plane)
        node.simdPosition = SIMD3<Float>(0, 0, -fogPlaneDistance)
        node.renderingOrder = fogPlaneRenderingOrder
        return node
    }

    /// Builds fog-coloured geometry for one mesh anchor, with per-vertex alpha
    /// driven by `confidences` (parallel to the anchor's vertices).
    ///
    /// `confidences` is passed in already resolved rather than looked up here,
    /// so the caller can hold the voxel-grid lock only for the cheap lookups and
    /// release it before this comparatively expensive buffer construction.
    static func makeGeometry(from meshGeometry: ARMeshGeometry, confidences: [Float]) -> SCNGeometry {
        let vertices = meshGeometry.vertices

        var colors = [SCNVector4]()
        colors.reserveCapacity(vertices.count)
        for index in 0..<vertices.count {
            // alpha 1 = fully fogged (never observed), alpha 0 = fully revealed.
            let confidence = index < confidences.count ? confidences[index] : 0
            let alpha = Float(fogAlpha) * (1 - confidence)
            colors.append(SCNVector4(Float(fogWhite), Float(fogWhite), Float(fogWhite), alpha))
        }

        let vertexSource = SCNGeometrySource(
            buffer: vertices.buffer,
            vertexFormat: vertices.format,
            semantic: .vertex,
            vertexCount: vertices.count,
            dataOffset: vertices.offset,
            dataStride: vertices.stride
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

        let faces = meshGeometry.faces
        let faceData = Data(bytes: faces.buffer.contents(), count: faces.buffer.length)
        let element = SCNGeometryElement(
            data: faceData,
            primitiveType: .triangles,
            primitiveCount: faces.count,
            bytesPerIndex: faces.bytesPerIndex
        )

        let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])

        let material = SCNMaterial()
        // White diffuse lets the per-vertex colours through unmodified.
        material.diffuse.contents = UIColor.white
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.blendMode = .alpha
        material.readsFromDepthBuffer = true
        // Load-bearing: this is what punches the hole in the fog plane. Without
        // it a revealed surface would still have the plane drawn over it.
        material.writesToDepthBuffer = true
        geometry.materials = [material]

        return geometry
    }
}
