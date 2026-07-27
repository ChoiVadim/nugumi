import Foundation
import NugumiToolWorkerCore

let delegate = ToolWorkerListenerDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
