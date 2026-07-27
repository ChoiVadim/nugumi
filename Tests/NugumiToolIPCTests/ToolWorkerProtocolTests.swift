import XCTest
@testable import NugumiToolIPC

final class ToolWorkerProtocolTests: XCTestCase {
    func testProbeRequestRoundTripsWithoutHostPathsInResult() throws {
        // Given
        let request = SandboxProbeRequest(
            runID: UUID(),
            deniedReadPath: "/Users/example/private.txt",
            deniedWritePath: "/Users/example/outside.txt",
            limits: .feasibility
        )

        // When
        let decoded = try JSONDecoder().decode(
            SandboxProbeRequest.self,
            from: JSONEncoder().encode(request)
        )

        // Then
        XCTAssertEqual(decoded, request)
    }

    func testGatePassRequiresEveryBoundaryCheck() {
        // Given
        var result = SandboxProbeResult.passingFixture

        // When
        result.rawNetworkDenied = false

        // Then
        XCTAssertFalse(result.gatePassed)
    }
}
