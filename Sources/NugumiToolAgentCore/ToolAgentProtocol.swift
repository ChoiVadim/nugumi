import Foundation

public enum ToolAgentProtocolErrorV1: Error, Equatable, Sendable {
    case frameTooLarge
    case unsupportedVersion
    case malformedMessage
}
