import Darwin
import Foundation

enum ProcessPIDFIFOError: Error {
    case system(errno: Int32)
    case deadline
    case invalidPID
}

final class ProcessPIDFIFO: @unchecked Sendable {
    let url: URL
    private let descriptor: Int32

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gizmate-process-\(UUID().uuidString).fifo")
        guard mkfifo(url.path, S_IRUSR | S_IWUSR) == 0 else {
            throw ProcessPIDFIFOError.system(errno: errno)
        }
        let openedDescriptor = open(url.path, O_RDWR | O_NONBLOCK)
        guard openedDescriptor >= 0 else {
            let errorNumber = errno
            unlink(url.path)
            throw ProcessPIDFIFOError.system(errno: errorNumber)
        }
        descriptor = openedDescriptor
    }

    deinit {
        close(descriptor)
        unlink(url.path)
    }

    func readPID() async throws -> pid_t {
        try await Task.detached {
            var event = pollfd(fd: self.descriptor, events: Int16(POLLIN), revents: 0)
            let pollResult = poll(&event, 1, 3_000)
            guard pollResult > 0 else {
                if pollResult < 0 {
                    throw ProcessPIDFIFOError.system(errno: errno)
                }
                throw ProcessPIDFIFOError.deadline
            }

            var buffer = [UInt8](repeating: 0, count: 64)
            let count = buffer.withUnsafeMutableBytes { bytes in
                read(self.descriptor, bytes.baseAddress, bytes.count)
            }
            guard count > 0 else {
                throw ProcessPIDFIFOError.system(errno: count < 0 ? errno : EIO)
            }
            let value = String(decoding: buffer[0..<count], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let pid = pid_t(value), pid > 1 else {
                throw ProcessPIDFIFOError.invalidPID
            }
            return pid
        }.value
    }
}
