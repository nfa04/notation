// Copyright (c) MASIC AI
// All rights reserved.
//
// This source code is licensed under the license found in the
// LICENSE file in the root directory of this source tree.

#import <Foundation/Foundation.h>
#if __has_include(<onnxruntime_objc/ort_session.h>)
#import <onnxruntime_objc/ort_session.h>  // CocoaPods
#else
#import "ort_session.h"  // SPM (OnnxRuntimeBindings public include dir on search path)
#endif

NS_ASSUME_NONNULL_BEGIN

/// Session options the ObjC wrapper does not offer, set through the underlying C++ API.
@interface SessionOptionsHelper : NSObject

/// Gives the free dimension [name] of the model's inputs the fixed [value] (AddFreeDimensionOverrideByName). With every input size
/// fixed, CoreML can build a model whose input size is otherwise free (it fails on such a model's dynamic part with error -14).
+ (BOOL)addFreeDimensionOverride:(ORTSessionOptions *)options
                            name:(NSString *)name
                           value:(int64_t)value
                           error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
