import XCTest
@testable import CoverageScout

final class FogRevealRendererTests: XCTestCase {
    func test_sampleIndicesStayUnderPreviewPointBudget() {
        let indices = FogRevealRenderer.sampleIndices(vertexCount: 10_000)

        XCTAssertLessThanOrEqual(indices.count, FogRevealRenderer.maximumPointsPerAnchor)
        XCTAssertEqual(indices.first, 0)
    }

    func test_samplingStrideUsesCeilingDivision() {
        XCTAssertEqual(FogRevealRenderer.samplingStride(vertexCount: FogRevealRenderer.maximumPointsPerAnchor), 1)
        XCTAssertEqual(FogRevealRenderer.samplingStride(vertexCount: FogRevealRenderer.maximumPointsPerAnchor + 1), 2)
    }
}
