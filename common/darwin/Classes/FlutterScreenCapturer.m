/*
 *  Copyright 2017 The WebRTC Project Authors. All rights reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#import <WebRTC/RTCLogging.h>
#import <WebRTC/RTCMediaConstraints.h>
#import "FlutterScreenCapturer.h"
#import "FlutterRPScreenRecorder.h"

@implementation FlutterScreenCapturer {
    NSDictionary *_constraints;
    BOOL _facing;
}

@synthesize facing = _facing;

- (instancetype)initWithVideoSource:(RTCVideoSource *)source
                 samplesInterceptor:(__weak id<SamplesInterceptorDelegate>)interceptorDelegate
                        constraints:(NSDictionary *)constraints{
    if (self = [super init]) {
        _screenRecorder = [[FlutterRPScreenRecorder alloc] initWithDelegate:source samplesInterceptor:interceptorDelegate];
        _constraints = constraints;
        _facing = NO;
    }
    return self;
}

- (void)startCapture:(OnSuccess)onSuccess onError:(OnError)onError {
    [_screenRecorder startCapture:onSuccess onError:onError];
}

- (void)restartCapture:(OnSuccess)onSuccess onError:(OnError)onError {
    [_screenRecorder stopCapture:^() {
        [self startCapture:onSuccess onError:onError];
    } onError:onError];
}

- (void)stopRunning:(OnSuccess)onSuccess onError:(OnError)onError {
    if (onError) {
        onError(@"!!! stopRunning not implemented %@ !!!", @"");
    }
}

- (void)startRunning:(OnSuccess)onSuccess onError:(OnError)onError {
    if (onError) {
        onError(@"!!! startRunning not implemented %@ !!!", @"");
    }
}

- (void)stopCapture:(OnSuccess)onSuccess onError:(OnError)onError {
    [_screenRecorder stopCapture:onSuccess onError:onError];
}

- (void)switchCamera:(OnSuccess)success onError:(OnError)onError {
    if (onError) {
        onError(@"!!! switchCamera not implemented %@ !!!", @"");
    }
}

@end
