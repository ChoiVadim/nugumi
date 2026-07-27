import Foundation

final class SendableXPCConnection: @unchecked Sendable {
    let value: NSXPCConnection

    init(_ value: NSXPCConnection) {
        self.value = value
    }
}
