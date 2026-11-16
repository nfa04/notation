// Copyright (c) MASIC AI
// All rights reserved.
//
// This source code is licensed under the license found in the
// LICENSE file in the root directory of this source tree.

#if __has_include("flutter_onnxruntime_objc/SessionOptionsHelper.h")
#import "flutter_onnxruntime_objc/SessionOptionsHelper.h"  // SPM (public headers under include/flutter_onnxruntime_objc/)
#else
#import "SessionOptionsHelper.h"  // CocoaPods
#endif
#import "ort_session_internal.h"
#import "cxx_api.h"

@implementation SessionOptionsHelper

+ (BOOL)addFreeDimensionOverride:(ORTSessionOptions *)options
                            name:(NSString *)name
                           value:(int64_t)value
                           error:(NSError **)error {
    try {
        [options CXXAPIOrtSessionOptions].AddFreeDimensionOverrideByName(name.UTF8String, value);
        return YES;
    } catch (const Ort::Exception &e) {
        if (error) {
            *error = [NSError errorWithDomain:@"com.masicai.flutter_onnxruntime"
                                         code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:e.what()]}];
        }
        return NO;
    }
}

@end
