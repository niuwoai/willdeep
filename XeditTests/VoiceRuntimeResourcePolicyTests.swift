import Testing
import Foundation
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

    @Test("voice model preload is opt-in to keep launch memory low")
    func voicePreloadDefaultsOff() {
        UserDefaults.standard.removeObject(forKey: "willdeep.voice.preloadOnLaunch")
        #expect(VoiceLifecyclePrefs.preloadOnLaunch == false)

        VoiceLifecyclePrefs.preloadOnLaunch = true
        #expect(VoiceLifecyclePrefs.preloadOnLaunch == true)

        UserDefaults.standard.removeObject(forKey: "willdeep.voice.preloadOnLaunch")
    }
}
