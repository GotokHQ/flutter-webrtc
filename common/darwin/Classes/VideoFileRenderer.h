//
//  MediaRecorder.h
//  Pods
//
//  Created by Onyemaechi Okafor on 1/23/19.
//
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <Flutter/Flutter.h>
#import <WebRTC/RTCVideoFrame.h>
#import <WebRTC/RTCVideoRenderer.h>
#import "SamplesInterceptorDelegate.h"

typedef void (^VideoFileRendererSuccessCallback)(void);
typedef void (^VideoFileRendererErrorCallback)(NSString *errorType, NSString *errorMessage);

@interface VideoFileRenderer : NSObject <SamplesInterceptorDelegate, RTCVideoRenderer>
@property (readonly, nonatomic) CGSize size;
@property (readonly, nonatomic) NSString* filePath;
@property (readonly, nonatomic) NSInteger duration;
@property (nonatomic, weak) FlutterEventSink eventSink;
@property (assign, nonatomic) BOOL isRecording;
@property (assign, nonatomic) BOOL isPaused;
@property (atomic, strong) RTCVideoFrame *videoFrame;
@property (assign, nonatomic) BOOL mirror;

- (instancetype)initWithPath:(NSString *)path size:(CGSize)size eventSink:(FlutterEventSink)sink audioOnly:(BOOL)audioOnly;
- (void)startVideoRecordingWithCompletion:(VideoFileRendererSuccessCallback)onComplete onError:(VideoFileRendererErrorCallback)onError;
- (void)stopVideoRecordingWithCompletion:(VideoFileRendererSuccessCallback)onComplete onError:(VideoFileRendererErrorCallback)onError;
- (void)setPaused:(BOOL)paused;
- (void)dispose;
@end
