import Foundation
import NugumiToolIPC
import XCTest
@testable import Nugumi

final class ToolWorkerReplyCoordinatorTests: XCTestCase {
    func testCandidateProtocolFailureHasStableClientClassification() throws {
        // Given
        let failure = CandidateWorkerProtocolFailureV1(
            code: .invalidRequest
        )
        let data = try JSONEncoder().encode(
            CandidateWorkerReplyV1.protocolFailure(failure)
        )

        // When
        XCTAssertThrowsError(try ToolWorkerClient.decodeCandidate(data)) {
            error in
            // Then
            XCTAssertEqual(
                error as? ToolWorkerClientError,
                .candidateProtocolFailure(failure)
            )
        }
    }

    func testEveryTerminalEventWinsExactlyOnceAgainstAllOtherEvents() {
        for winner in terminalEvents {
            var outcomes: [ReplyOutcome] = []
            var invalidationCount = 0
            let coordinator = ToolWorkerReplyCoordinator {
                invalidationCount += 1
            }
            coordinator.install { outcomes.append(Self.outcome($0)) }

            coordinator.receive(winner)
            terminalEvents.forEach(coordinator.receive)

            XCTAssertEqual(outcomes, [Self.outcome(for: winner)])
            XCTAssertEqual(invalidationCount, 1)
        }
    }

    func testTerminalEventBeforeInstallStillCompletesAndInvalidatesOnce() {
        var outcomes: [ReplyOutcome] = []
        var invalidationCount = 0
        let coordinator = ToolWorkerReplyCoordinator {
            invalidationCount += 1
        }

        coordinator.receive(.reply(Data([0x2A])))
        coordinator.receive(.remoteProxyError)
        coordinator.receive(.interruption)
        coordinator.install { outcomes.append(Self.outcome($0)) }
        coordinator.receive(.invalidation)
        coordinator.receive(.cancellation)

        XCTAssertEqual(outcomes, [.success(Data([0x2A]))])
        XCTAssertEqual(invalidationCount, 1)
    }

    private var terminalEvents: [ToolWorkerReplyEvent] {
        [
            .reply(Data([0x2A])),
            .remoteProxyError,
            .interruption,
            .invalidation,
            .cancellation,
        ]
    }

    private static func outcome(
        for event: ToolWorkerReplyEvent
    ) -> ReplyOutcome {
        switch event {
        case let .reply(data):
            return .success(data)
        case .remoteProxyError, .interruption, .invalidation:
            return .failure(.connectionUnavailable)
        case .cancellation:
            return .failure(.cancelled)
        }
    }

    private static func outcome(
        _ result: Result<Data, Error>
    ) -> ReplyOutcome {
        switch result {
        case let .success(data):
            return .success(data)
        case let .failure(error):
            return .failure(
                (error as? ToolWorkerClientError) ?? .invalidReply
            )
        }
    }
}

private enum ReplyOutcome: Equatable {
    case success(Data)
    case failure(ToolWorkerClientError)
}
