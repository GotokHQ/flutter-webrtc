/*
 *  Copyright 2017 The WebRTC Project Authors. All rights reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#import "FlutterFileCapturer.h"

#import <WebRTC/RTCLogging.h>
#import <WebRTC/RTCFileVideoCapturer.h>
#import <WebRTC/RTCMediaConstraints.h>


@implementation FlutterFileCapturer {
    RTCFileVideoCapturer *_capturer;
    NSDictionary *_constraints;
}

- (instancetype)initWithVideoSource:(RTCVideoSource *)source constraints:(NSDictionary *)constraints{
    if (self = [super init]) {
        _capturer = [[RTCFileVideoCapturer alloc] initWithDelegate: source];
        _constraints = constraints;
    }

    return self;
}

- (void)startCapture:(OnSuccess)success onError:(OnError)errorCallback {
    NSString *file = _constraints[@"file"];
    if (file) {
      [_capturer startCapturingFromFileNamed:file
                                             onError:^(NSError *_Nonnull error) {
                                               NSLog(@"Error %@", error.userInfo);
                                                 errorCallback(error.userInfo[@"code"], [NSString stringWithFormat:@"Error %@", error.userInfo[@"error"]]);
                                             }];
       if (success) {
            success();
       }
    } else {
       if (errorCallback) {
           errorCallback(@"OverconstrainedError", @"FileNotFoundError");
       }
    }
}

- (void)stopCapture:(OnSuccess)success onError:(OnError)error  {
    [_capturer stopCapture];
    if (success) {
        success();
    }
}

- (void)switchCamera:(OnSuccess)success onError:(OnError)error {
}

@end
