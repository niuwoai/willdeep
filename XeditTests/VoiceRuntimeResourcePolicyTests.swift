import Testing
@testable import WillDeep

struct VoiceRuntimeResourcePolicyTests {
    @Test("ONNX voice runtime caps inference threads for long-running app thermals")
    func onnxThreadPolicyCapsCpuUsage() {
        #expect(ONNXRuntimeWrapper.balancedThreadCount(activeProcessorCount: 1) == 1)
        #expect(ONNXRuntimeWrapper.balancedThreadCount(activeProcessorCount: 2) == 2)
        #expect(ONNXRuntimeWrapper.balancedThreadCount(activeProcessorCount: 4) == 2)
        #expect(ONNXRuntimeWrapper.balancedThreadCount(activeProcessorCount: 8) == 4)
        #expect(ONNXRuntimeWrapper.balancedThreadCount(activeProcessorCount: 16) == 4)
    }
}
