import Foundation
import NugumiToolIPC

final class ToolWorkerListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        connection.exportedInterface = NSXPCInterface(
            with: NugumiToolWorkerProtocol.self
        )
        connection.exportedObject = ToolWorkerService(connection: connection)
        connection.remoteObjectInterface = NSXPCInterface(
            with: NugumiToolWorkerHostProtocol.self
        )
        connection.resume()
        return true
    }
}
