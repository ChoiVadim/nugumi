import Foundation
import NugumiToolIPC

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
        return components.scheme == "https"
            && components.host == "example.com"
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

final class ProbeFixtureProxy: NSObject, NugumiToolWorkerHostProtocol {
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
            reply(Self.encode(ProbeFixturePolicy.response(statusCode: nil, body: Data())))
            return
        }
        ProbeFixtureFetch(url: request.url) { response in
            reply(Self.encode(response))
        }.start()
    }

    private static func encode(_ response: ProbeFixtureResponse) -> Data {
        (try? JSONEncoder().encode(response)) ?? Data()
    }
}

private final class ProbeFixtureFetch: NSObject, URLSessionDataDelegate {
    private let url: URL
    private let completion: (ProbeFixtureResponse) -> Void
    private var session: URLSession?
    private var body = Data()
    private var statusCode: Int?
    private var completed = false

    init(url: URL, completion: @escaping (ProbeFixtureResponse) -> Void) {
        self.url = url
        self.completion = completion
    }

    func start() {
        let session = URLSession(
            configuration: ProbeFixturePolicy.sessionConfiguration(),
            delegate: self,
            delegateQueue: nil
        )
        self.session = session
        session.dataTask(with: url).resume()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let redirectAllowed = ProbeFixturePolicy.allowsRedirect(
            to: request.url ?? url
        )
        completionHandler(redirectAllowed ? request : nil)
        guard !redirectAllowed else { return }
        finish(statusCode: response.statusCode, body: Data())
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(statusCode: nil, body: Data())
            return
        }
        statusCode = response.statusCode
        guard response.statusCode == 200 else {
            completionHandler(.cancel)
            finish(statusCode: response.statusCode, body: Data())
            return
        }
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        guard body.count + data.count <= ProbeFixturePolicy.bodyLimit else {
            dataTask.cancel()
            finish(statusCode: statusCode, body: Data())
            return
        }
        body.append(data)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        finish(statusCode: statusCode, body: error == nil ? body : Data())
    }

    private func finish(statusCode: Int?, body: Data) {
        guard !completed else { return }
        completed = true
        completion(ProbeFixturePolicy.response(statusCode: statusCode, body: body))
        session?.finishTasksAndInvalidate()
        session = nil
    }
}
