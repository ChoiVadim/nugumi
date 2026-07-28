import Combine
import XCTest
@testable import Nugumi

@MainActor
final class FullDiskAccessProbeTests: XCTestCase {
    func testModelInitializationDoesNotWaitForFullDiskAccessProbe() async {
        let probe = SuspendedFullDiskAccessProbe()

        let model = OnboardingModel(
            mode: .review,
            fullDiskAccessProbe: { await probe.run() }
        )

        XCTAssertFalse(model.fdaGranted)
        await probe.waitUntilStarted()
        let initialCallCount = await probe.callCount
        XCTAssertEqual(initialCallCount, 1)

        let updated = expectation(description: "Full Disk Access status updated")
        let observation = model.$fdaGranted
            .dropFirst()
            .filter { $0 }
            .sink { _ in updated.fulfill() }
        await probe.finish(with: true)
        await fulfillment(of: [updated], timeout: 1)
        XCTAssertTrue(model.fdaGranted)
        withExtendedLifetime(observation) {}
    }

    func testRefreshDoesNotStartOverlappingFullDiskAccessProbes() async {
        let probe = SuspendedFullDiskAccessProbe()
        let model = OnboardingModel(
            mode: .review,
            fullDiskAccessProbe: { await probe.run() }
        )
        await probe.waitUntilStarted()

        model.refreshPermissions()
        model.refreshPermissions()

        let callCount = await probe.callCount
        XCTAssertEqual(callCount, 1)
        let updated = expectation(description: "Only in-flight probe completed")
        let observation = model.$fdaGranted
            .dropFirst()
            .filter { $0 }
            .sink { _ in updated.fulfill() }
        await probe.finish(with: true)
        await fulfillment(of: [updated], timeout: 1)
        withExtendedLifetime(observation) {}
    }
}

private actor SuspendedFullDiskAccessProbe {
    private(set) var callCount = 0
    private var result: Bool?
    private var resultWaiter: CheckedContinuation<Bool, Never>?
    private var startWaiter: CheckedContinuation<Void, Never>?

    func run() async -> Bool {
        callCount += 1
        startWaiter?.resume()
        startWaiter = nil
        if let result { return result }
        return await withCheckedContinuation { resultWaiter = $0 }
    }

    func waitUntilStarted() async {
        guard callCount == 0 else { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func finish(with value: Bool) {
        result = value
        resultWaiter?.resume(returning: value)
        resultWaiter = nil
    }
}
