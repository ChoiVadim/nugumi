import CToolSandbox
import Darwin
import XCTest

final class CToolSandboxTests: XCTestCase {
    func testDuplicateToSameDescriptorClearsCloseOnExec() {
        // Given
        var descriptors = [Int32](repeating: 0, count: 2)
        XCTAssertEqual(pipe(&descriptors), 0)
        defer {
            close(descriptors[0])
            close(descriptors[1])
        }
        let descriptor = descriptors[1]
        XCTAssertEqual(fcntl(descriptor, F_SETFD, FD_CLOEXEC), 0)

        // When
        let result = gizmate_dup2_clearing_cloexec(descriptor, descriptor)

        // Then
        XCTAssertEqual(result, 0)
        XCTAssertEqual(fcntl(descriptor, F_GETFD) & FD_CLOEXEC, 0)
    }
}
