// VENDORED from https://github.com/masicai/onnxruntime-swift-package-manager tag 1.28.0 (objectivec/ort_session_internal.h);
// Internal header of the onnxruntime ObjC bindings, not exposed by the SPM package or CocoaPods pod.
// Required for free dimension overrides (SessionOptionsHelper: a model's free input size fixed, so CoreML can build it).
// MUST stay byte-identical (below this comment) to the pinned onnxruntime version — re-diff on every ORT bump.
// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

#import "ort_session.h"

#import "cxx_api.h"

NS_ASSUME_NONNULL_BEGIN

@interface ORTSessionOptions ()

- (Ort::SessionOptions&)CXXAPIOrtSessionOptions;

@end

@interface ORTRunOptions ()

- (Ort::RunOptions&)CXXAPIOrtRunOptions;

@end

NS_ASSUME_NONNULL_END
