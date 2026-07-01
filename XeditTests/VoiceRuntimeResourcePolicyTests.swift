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

    @Test("voice transcript language preference can follow system or force Japanese")
    func voiceTranscriptLanguagePreferenceResolvesLanguages() {
        #expect(VoiceTranscriptLanguagePreference.systemTranscriptLanguage(preferredLanguages: ["ja-JP"]) == .ja)
        #expect(VoiceTranscriptLanguagePreference.systemTranscriptLanguage(preferredLanguages: ["zh-Hans-CN"]) == .zh)
        #expect(VoiceTranscriptLanguagePreference.systemTranscriptLanguage(preferredLanguages: ["en-US"]) == .en)
        #expect(VoiceTranscriptLanguagePreference.systemTranscriptLanguage(preferredLanguages: ["ko-KR"]) == .ko)
        #expect(VoiceTranscriptLanguagePreference.systemTranscriptLanguage(preferredLanguages: ["fr-FR"]) == .auto)

        #expect(VoiceTranscriptLanguagePreference.ja.transcriptLanguage == .ja)
        #expect(VoiceTranscriptLanguagePreference.auto.transcriptLanguage == .auto)
    }
}
