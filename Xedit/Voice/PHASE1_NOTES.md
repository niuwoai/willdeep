# Voice-to-text — Phase 1 status

## What's in this directory

Ported from `~/Sites/fastv` (a.k.a. 妙打 / FastV):
- **Swift STT pipeline**:
  - `SpeechTranscriber.swift` — main entry point (`SpeechTranscriber.transcribe(audioURL:language:enableCTCDeduplication:)`)
  - `ONNXRuntimeWrapper.swift` + `ONNXRuntimeCWrapper.swift` — Swift veneer over the ONNX Runtime C API
  - `ONNXRuntimeBridge.h` — Objective-C bridge exposing the ONNX C API to Swift
  - `AudioFeatureExtractor.swift` — mel-spectrogram extraction (uses Kaldi fbank)
  - `KaldiFbankWrapper.swift` + `KaldiFbankBridge.{h,mm}` — Kaldi-native-fbank bridge
  - `SilenceDetector.swift` — VAD
  - `SpeechTranscriptionModel.swift` — output data structures
  - `VoiceRecording.swift`, `TranscriptLanguage.swift` — supporting models
- **WillDeep-specific glue** (new in this branch):
  - `VoiceConfig.swift` — `UserPreferences` shim + `VoiceModelLocation` paths
- **Native deps**:
  - `Libraries/onnxruntime/libonnxruntime.1.23.2.dylib` (~71 MB, macOS universal2)
  - `Libraries/onnxruntime/include/` — ONNX Runtime C/C++ headers
  - `Libraries/kaldi-native-fbank/csrc/` — Kaldi fbank C++ source (compiled into the bridge .mm via `#include`)

The Kaldi `.cc/.c` files are listed in the project's
`membershipExceptions` so PBXFileSystemSynchronizedRootGroup does NOT
add them to Compile Sources directly — they're inline-included into
`KaldiFbankBridge.mm` to form one translation unit (matches fastv's
strategy). The ONNX dylib is similarly excluded from auto-compile
membership (it gets linked separately via the steps below).

## What's left for phase 1 to actually compile + run

These are all **Xcode project-level** changes I deliberately did not
automate this turn — pbxproj is fragile and the safer path is to do
them by hand in Xcode once and commit the diff:

1. **Add `libonnxruntime.1.23.2.dylib` to "Frameworks, Libraries, and
   Embedded Content"** on the Xedit target. Set Embed to "Embed &
   Sign". Xcode will create the right PBXBuildFile + PBXFrameworksBuildPhase
   entry.

2. **Add a Run Script Build Phase** named something like
   "Copy + sign ONNX Runtime dylib" — based on the script from
   fastv's pbxproj (see git log there for the exact text). It:
   - Copies `libonnxruntime.1.23.2.dylib` into `Contents/Frameworks/`
   - Creates the `libonnxruntime.dylib` symlink
   - Re-signs the dylib with the build's signing identity

3. **Build Settings → Header Search Paths**, add:
   - `$(SRCROOT)/Xedit/Voice/Libraries/onnxruntime/include`
   - `$(SRCROOT)/Xedit/Voice/Libraries/kaldi-native-fbank`

4. **Build Settings → Library Search Paths**, add:
   - `$(SRCROOT)/Xedit/Voice/Libraries/onnxruntime`

5. **Build Settings → Other Linker Flags**, add `-lonnxruntime`.

6. **Build Settings → Other C++ Flags**, add `-std=c++17` (Kaldi
   needs at least C++14; 17 is safer).

7. **Info.plist** — add `NSMicrophoneUsageDescription` (string
   explaining why mic access is needed). Phase 1 doesn't record yet
   but the entitlement should land at the same time so the user only
   sees one permission prompt.

8. **`WillDeep.entitlements`** — add `com.apple.security.device.audio-input`.

## What works after that

`SpeechTranscriber.transcribe(audioURL: URL, language: .auto)` should
read a WAV/M4A/MP3 file from disk and return a transcript string, as
long as the SenseVoice ONNX model is already downloaded to
`~/Library/Application Support/WillDeep/Voice/Models/sensevoice-small/`
(`model.onnx`, `tokens.json`, `am.mvn`).

## Phase 2+ (queued, not in this branch yet)

- `WhisperPreflight` + WillDeep-flavored `ModelDownloader` — onboarding
  sheet that fetches the SenseVoice model on first use (~234 MB).
- `TranscribeWorkflow` — `/transcribe <audio-path>` slash command that
  runs the pipeline and outputs a timestamped markdown report.
- Composer mic button + push-to-talk shortcut.
- `/video-summary` (yt-dlp → audio + frame grabs → STT + multimodal LLM).
- `/meeting-notes` (STT + speaker diarization → action items / decisions).

## Open question for the next session

Some of the ported code (`IncrementalTranscriptionManager`,
`SystemAudioCaptureService`, the realtime path in `SpeechTranscriber`)
references symbols that aren't yet in this branch. Phase 1's MVP is
**batch transcription of a file on disk**, so those code paths
shouldn't be hit. If they cause compile errors, it's safer to delete
or `#if false`-guard them in this branch than to drag in more
fastv-specific dependencies. We'll revisit when we add live recording.
