import Foundation

struct PythonProbeOutput: Decodable {
    let pythonVersion: String
    let dependencyVersion: String
    let workspaceWriteSucceeded: Bool
    let hostReadDenied: Bool
    let hostWriteDenied: Bool
    let rawNetworkDenied: Bool
    let mediatedNetworkSucceeded: Bool

    private enum CodingKeys: String, CodingKey {
        case pythonVersion = "python_version"
        case dependencyVersion = "dependency_version"
        case workspaceWriteSucceeded = "workspace_write_succeeded"
        case hostReadDenied = "host_read_denied"
        case hostWriteDenied = "host_write_denied"
        case rawNetworkDenied = "raw_network_denied"
        case mediatedNetworkSucceeded = "mediated_network_succeeded"
    }
}
