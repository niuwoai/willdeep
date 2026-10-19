import Foundation

/// MCP stdio is newline-delimited UTF-8. Scan each arriving byte once, even
/// when a large base64 result arrives in thousands of separate pipe reads.
nonisolated struct AgentMCPLineFramer {
    private var buffer = Data()
    private var scannedByteCount = 0

    mutating func append(_ data: Data) -> [Data] {
        guard !data.isEmpty else { return [] }
        buffer.append(data)
        var lineStart = 0
        let lines: [Data] = buffer.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var result: [Data] = []
            for index in scannedByteCount..<bytes.count where bytes[index] == 0x0A {
                result.append(Data(bytes[lineStart..<index]))
                lineStart = index + 1
            }
            return result
        }
        if lineStart > 0 {
            buffer.removeFirst(lineStart)
        }
        scannedByteCount = buffer.count
        return lines
    }
}
