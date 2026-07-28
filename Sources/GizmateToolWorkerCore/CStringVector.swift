import Darwin

enum CStringVectorError: Error {
    case invalidString
    case outOfMemory
}

final class CStringVector {
    private let storage: [UnsafeMutablePointer<CChar>]
    private var pointers: [UnsafeMutablePointer<CChar>?]

    init(_ strings: [String]) throws {
        guard strings.allSatisfy({ !$0.utf8.contains(0) }) else {
            throw CStringVectorError.invalidString
        }

        var allocated: [UnsafeMutablePointer<CChar>] = []
        allocated.reserveCapacity(strings.count)
        for string in strings {
            guard let pointer = strdup(string) else {
                allocated.forEach { free($0) }
                throw CStringVectorError.outOfMemory
            }
            allocated.append(pointer)
        }
        storage = allocated
        pointers = allocated.map(Optional.some) + [nil]
    }

    deinit {
        storage.forEach { free($0) }
    }

    func withUnsafeMutablePointer<Result>(
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
    ) rethrows -> Result {
        try pointers.withUnsafeMutableBufferPointer { buffer in
            try body(buffer.baseAddress!)
        }
    }
}
