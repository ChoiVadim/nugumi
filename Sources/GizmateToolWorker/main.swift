import Foundation
import GizmateToolWorkerCore

let delegate = ToolWorkerListenerDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
