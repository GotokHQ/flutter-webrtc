//
//  FlutterScreenCapturer.m
//  Pods-Runner
//
//  Created by Onyemaechi Okafor on 8/12/19.
//

#include <WebRTC/WebRTC.h>
#import "SamplesInterceptorDelegate.h"
#import "FlutterVideoCapturer.h"
#import "FlutterRPScreenRecorder.h"


@interface FlutterScreenCapturer : NSObject<FlutterVideoCapturer>

@property(readonly, nonatomic) FlutterRPScreenRecorder* screenRecorder;

- (instancetype)initWithVideoSource:(RTCVideoSource *)source
                 samplesInterceptor:(__weak id<SamplesInterceptorDelegate>)interceptorDelegate
                        constraints:(NSDictionary *)constraints;

- (void)startCapture:(OnSuccess)success onError:(OnError)error;
- (void)stopCapture:(OnSuccess)success onError:(OnError)error;
- (void)switchCamera:(OnSuccess)success onError:(OnError)error;
- (void)restartCapture:(OnSuccess)success onError:(OnError)onError;
- (void)stopRunning:(OnSuccess)success onError:(OnError)onError;
- (void)startRunning:(OnSuccess)success onError:(OnError)onError;
@end
