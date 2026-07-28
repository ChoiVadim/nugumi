import Foundation
import GizmateToolIPC

struct ToolWorkerProbeMode: Equatable {
    let reportPath: String

    var reportURL: URL {
        URL(fileURLWithPath: reportPath)
    }

    static func parse(arguments: [String]) -> Self? {
        guard
            arguments.count == 4,
            arguments[1] == "--tool-worker-probe",
            arguments[2] == "--report",
            !arguments[3].isEmpty
        else {
            return nil
        }
        return Self(reportPath: arguments[3])
    }
}

enum ProbeFixturePolicy {
    static let bodyLimit = 64 * 1_024

    static func accepts(_ url: URL) -> Bool {
        guard let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else {
            return false
        }
        return acceptsNormalized(components)
    }

    private static func acceptsNormalized(_ components: URLComponents) -> Bool {
        components.scheme?.lowercased() == "https"
            && components.host?.lowercased() == "example.com"
            && components.percentEncodedHost?.lowercased() == "example.com"
            && (components.port == nil || components.port == 443)
            && components.path == "/"
            && components.user == nil
            && components.password == nil
            && components.query == nil
            && components.fragment == nil
    }

    static func allowsRedirect(to url: URL) -> Bool {
        false
    }

    static func response(statusCode: Int?, body: Data) -> ProbeFixtureResponse {
        let accepted = statusCode == 200 && body.count <= bodyLimit
        return ProbeFixtureResponse(
            accepted: accepted,
            statusCode: statusCode,
            body: accepted ? body : Data()
        )
    }

    static func rejection(statusCode: Int?) -> ProbeFixtureResponse {
        ProbeFixtureResponse(
            accepted: false,
            statusCode: statusCode,
            body: Data()
        )
    }

    static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return configuration
    }
}

final class ProbeFixtureProxy: NSObject, GizmateToolWorkerHostProtocol {
    func fetchProbeFixture(
        _ requestData: Data,
        withReply reply: @escaping (Data) -> Void
    ) {
        guard
            let request = try? JSONDecoder().decode(
                ProbeFixtureRequest.self,
                from: requestData
            ),
            ProbeFixturePolicy.accepts(request.url)
        else {
            reply(Self.encode(ProbeFixturePolicy.rejection(statusCode: nil)))
            return
        }
        Task {
            let response = await ProbeFixtureTransport.fetch(request.url)
            reply(Self.encode(response))
        }
    }

    private static func encode(_ response: ProbeFixtureResponse) -> Data {
        (try? JSONEncoder().encode(response)) ?? Data()
    }
}
