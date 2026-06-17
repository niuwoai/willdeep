//
//  WillDeep-Bridging-Header.h
//  WillDeep
//

#import "AIPipe.h"

// Phase 1 voice-to-text (feat/voice-to-text branch). These headers are
// only useful once the ONNX Runtime dylib + Kaldi sources are actually
// linked into the target — see Voice/PHASE1_NOTES.md for the Xcode
// project-level wiring still to do.
#import "Voice/ONNXRuntimeBridge.h"
#import "Voice/KaldiFbankBridge.h"
