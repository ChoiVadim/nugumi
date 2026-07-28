import Foundation
import GizmateToolIPC

final class ToolWorkerListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        connection.exportedInterface = NSXPCInterface(
            with: GizmateToolWorkerProtocol.self
        )
        connection.exportedObject = ToolWorkerService(connection: connection)
        connection.remoteObjectInterface = NSXPCInterface(
            with: GizmateToolWorkerHostProtocol.self
        )
        connection.resume()
        return true
    }
}
