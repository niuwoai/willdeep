import Foundation
import Testing
@testable import WillDeep

@Suite
struct AgentMCPLineFramerTests {
    @Test
    func preservesFragmentedUTF8AndMultipleLines() throws {
        var framer = AgentMCPLineFramer()
        let input = Data("{\"text\":\"中文🙂\"}\r\n\n{\"id\":2}\npartial".utf8)
        var lines: [Data] = []
        for byte in input { lines += framer.append(Data([byte])) }
        #expect(lines.map { String(data: $0, encoding: .utf8) } == [
            "{\"text\":\"中文🙂\"}\r", "", "{\"id\":2}"
        ])
        #expect(framer.append(Data()).isEmpty)
        #expect(framer.append(Data(" tail\n".utf8)) == [Data("partial tail".utf8)])
    }

    @Test
    func handlesSlicedDataAndPartialTailAfterCompletedLine() {
        var framer = AgentMCPLineFramer()
        let sliced = Data("xxfirst\nsec".utf8).dropFirst(2)
        #expect(framer.append(sliced) == [Data("first".utf8)])
        #expect(framer.append(Data("ond\nthird\nfourth".utf8)) == [
            Data("second".utf8), Data("third".utf8)
        ])
        #expect(framer.append(Data("\n".utf8)) == [Data("fourth".utf8)])
    }

    @Test
    func reconstructsLargeResultAcrossPipeSizedChunks() {
        var framer = AgentMCPLineFramer()
        let payload = Data(repeating: 0x61, count: 4 * 1024 * 1024)
        let chunkSize = 4096
        for start in stride(from: 0, to: payload.count, by: chunkSize) {
            #expect(framer.append(payload[start..<min(start + chunkSize, payload.count)]).isEmpty)
        }
        #expect(framer.append(Data([0x0A])) == [payload])
        #expect(framer.append(Data("next\n".utf8)) == [Data("next".utf8)])
    }
}
