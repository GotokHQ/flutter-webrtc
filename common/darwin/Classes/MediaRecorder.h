//
//  MediaRecorder.h
//  Pods
//
//  Created by Onyemaechi Okafor on 1/23/19.
//
#import "FlutterWebRTCPlugin.h"
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <Flutter/Flutter.h>
#import <WebRTC/RTCVideoTrack.h>
#import <WebRTC/RTCVideoFrame.h>
#import "FlutterRecorder.h"
#import "SamplesInterceptor.h"
#import "SamplesInterceptorDelegate.h"

@interface MediaRecorder : NSObject <SamplesInterceptorDelegate, FlutterStreamHandler, FlutterRecorder, CameraSwitchObserver>
@property(readonly, nonatomic) CGSize size;
@property(nonatomic) FlutterEventSink eventSink;
@property(nonatomic) FlutterEventChannel *eventChannel;
@property(assign, nonatomic) BOOL isRecording;

- (instancetype)initWithRecorderId:(NSNumber *)recorderId videoSize:(CGSize)size samplesInterceptor:(SamplesInterceptor*)samplesInterceptor messenger:(NSObject<FlutterBinaryMessenger>*)messenger audioOnly:(BOOL)audioOnly;
- (void)startVideoRecordingAtPath:(NSString *)path result:(FlutterResult)result;
- (void)stopVideoRecordingWithResult:(FlutterResult)result;
- (void)setPaused:(BOOL)paused;
- (void)dispose;
+ (NSDictionary *)extractAudioMetadataWithFile:(NSString *)filename;
+ (NSDictionary *)extractVideoMetadataWithFile:(NSString *)filename videoSize:(CGSize)videoSize options:(MetaDataOptions*)options;
@end

@interface FlutterWebRTCPlugin (MediaRecorder)

- (MediaRecorder *)createMediaRecorder:(NSNumber *)recorderId size:(CGSize)size samplesInterceptor:(SamplesInterceptor*)samplesInterceptor audioOnly:(BOOL)audioOnly;

@end
