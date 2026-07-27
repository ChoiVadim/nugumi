import Foundation
import NugumiToolIPC

struct ProbeFixtureByteStream {
    let next: () async throws -> UInt8?
    let cancel: () -> Void
    let finish: () -> Void
}

struct ProbeFixtureStreamResponse {
    let statusCode: Int
    let expectedContentLength: Int64
    let redirected: Bool
    let stream: ProbeFixtureByteStream
}

enum ProbeFixtureLoader {
    static func load(
        response: ProbeFixtureStreamResponse
    ) async -> ProbeFixtureResponse {
        let expectedLength = response.expectedContentLength
        let expectedLengthAccepted = expectedLength == -1
            || (0...Int64(ProbeFixturePolicy.bodyLimit)).contains(expectedLength)
        guard
            response.statusCode == 200,
            !response.redirected,
            expectedLengthAccepted
        else {
            response.stream.cancel()
            return ProbeFixturePolicy.rejection(statusCode: response.statusCode)
        }

        var body = Data()
        body.reserveCapacity(
            min(
                max(Int(expectedLength), 0),
                ProbeFixturePolicy.bodyLimit
            )
        )
        do {
            while let byte = try await response.stream.next() {
                guard body.count < ProbeFixturePolicy.bodyLimit else {
                    response.stream.cancel()
                    return ProbeFixturePolicy.rejection(
                        statusCode: response.statusCode
                    )
                }
                body.append(byte)
            }
            response.stream.finish()
            return ProbeFixturePolicy.response(
                statusCode: response.statusCode,
                body: body
            )
        } catch {
            response.stream.cancel()
            return ProbeFixturePolicy.rejection(statusCode: response.statusCode)
        }
    }
}

enum ProbeFixtureTransport {
    static func fetch(_ url: URL) async -> ProbeFixtureResponse {
        let session = URLSession(
            configuration: ProbeFixturePolicy.sessionConfiguration()
        )
        let redirectDelegate = ProbeRedirectDelegate()
        var request = URLRequest(url: url)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        do {
            let (bytes, response) = try await session.bytes(
                for: request,
                delegate: redirectDelegate
            )
            guard let httpResponse = response as? HTTPURLResponse else {
                session.invalidateAndCancel()
                return ProbeFixturePolicy.rejection(statusCode: nil)
            }
            let iterator = AsyncByteIterator(bytes: bytes)
            return await ProbeFixtureLoader.load(
                response: ProbeFixtureStreamResponse(
                    statusCode: httpResponse.statusCode,
                    expectedContentLength: response.expectedContentLength,
                    redirected: redirectDelegate.wasRedirected,
                    stream: ProbeFixtureByteStream(
                        next: iterator.next,
                        cancel: session.invalidateAndCancel,
                        finish: session.finishTasksAndInvalidate
                    )
                )
            )
        } catch {
            session.invalidateAndCancel()
            return ProbeFixturePolicy.rejection(statusCode: nil)
        }
    }
}

private final class AsyncByteIterator: @unchecked Sendable {
    private var iterator: URLSession.AsyncBytes.Iterator

    init(bytes: URLSession.AsyncBytes) {
        iterator = bytes.makeAsyncIterator()
    }

    func next() async throws -> UInt8? {
        try await iterator.next()
    }
}

private final class ProbeRedirectDelegate: NSObject, URLSessionTaskDelegate {
    private let lock = NSLock()
    private var redirected = false

    var wasRedirected: Bool {
        lock.withLock { redirected }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.withLock { redirected = true }
        guard let target = request.url else {
            completionHandler(nil)
            return
        }
        completionHandler(
            ProbeFixturePolicy.allowsRedirect(to: target)
                ? request
                : nil
        )
    }
}
