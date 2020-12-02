//
//  MediaRecorder.m
//  Pods-Runner
//
//  Created by Onyemaechi Okafor on 1/23/19.
//

#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CGImage.h>
#import <WebRTC/RTCVideoFrameBuffer.h>
#import <WebRTC/RTCVideoFrame.h>
#import <WebRTC/RTCVideoViewShading.h>
#import <WebRTC/RTCLogging.h>
#import <WebRTC/RTCCVPixelBuffer.h>
#import "NSError+FlutterError.h"
#import <WebRTC/RTCAudioTrack.h>
#import <WebRTC/RTCVideoTrack.h>
#import "FlutterCameraCapturer.h"
#import "FlutterVideoCapturer.h"
#import "FlutterRTCVideoSource.h"
#import "MediaRecorder.h"
#import "VideoFileRenderer.h"

@implementation MediaRecorder
{
    
    FlutterEventChannel* _eventChannel;
    VideoFileRenderer *_videoFileRenderer;
    SamplesInterceptor *_samplesInterceptor;
    RTCVideoTrack *_videoTrack;
    BOOL _mirror;
    BOOL _audioOnly;
}

- (instancetype)initWithRecorderId:(NSNumber *)recorderId videoSize:(CGSize)size samplesInterceptor:(SamplesInterceptor*)samplesInterceptor messenger:(NSObject<FlutterBinaryMessenger>*)messenger audioOnly:(BOOL)audioOnly{
    self = [super init];
    _size = size;
    _audioOnly = audioOnly;
    _eventChannel = [FlutterEventChannel
                     eventChannelWithName:[NSString stringWithFormat:@"FlutterWebRTC/mediaRecorderEvents/%@", recorderId]
                     binaryMessenger:messenger];
    [_eventChannel setStreamHandler:self];
    _samplesInterceptor = samplesInterceptor;
    _mirror = NO;
    return self;
}

- (void)addVideoTrack:(RTCVideoTrack *)videoTrack isRemote:(BOOL)remote label:(NSString*)label{
    RTCVideoTrack *oldValue = _videoTrack;
    if (oldValue != videoTrack) {
        if (oldValue && _videoFileRenderer) {
            // NSLog(@"Remove old video track for : %lld", _textureId);
            //[_samplesInterceptor removeSampleInterceptor:_videoFileRenderer];
            [self releaseVideoFileRenderer];
            _videoFileRenderer = nil;
        }
        _videoTrack = videoTrack;
        if (videoTrack) {
            RTCVideoSource *source = videoTrack.source;
            if (source.capturer) {
                _mirror = source.capturer.facing;
            }
        }
    }
}

- (void)removeVideoTrack:(RTCVideoTrack *)videoTrack isRemote:(BOOL)remote label:(NSString*)label {
    [self addVideoTrack: nil isRemote:remote label:label];
}

- (void)startVideoRecordingAtPath:(NSString *)path result:(FlutterResult)result {
    NSLog(@"startVideoRecordingAtPath %@", path);
    if (!_isRecording) {
        if (_videoTrack) {
            _videoFileRenderer = [[VideoFileRenderer alloc] initWithPath:path size:_size eventSink:_eventSink audioOnly:_audioOnly];
            [_videoTrack addRenderer:_videoFileRenderer];
            // [_samplesInterceptor addSampleInterceptor:_videoFileRenderer];
            FlutterCameraCapturer *capturer = (FlutterCameraCapturer*)_videoTrack.source.capturer;
            capturer.camera.audioSamplesInterceptorDelegate = self;
            _videoFileRenderer.mirror = _mirror;
            NSLog(@"Started recording at path %@", path);
            NSLog(@"Started recording with mirror %d", _mirror);
            [_videoFileRenderer startVideoRecordingWithCompletion:^{
                self->_isRecording = YES;
                result(nil);
                
            } onError:^(NSString *errorType, NSString *errorMessage){
                NSLog(@"Failed to setup writing at path %@", path);
                result([FlutterError errorWithCode:errorType
                                           message:errorMessage
                                           details:nil]);
            }];
        } else {
            if (_samplesInterceptor) {
                //TODO(peerwaya): audio only recording
            }
        }
    } else {
        NSLog(@"failed to start recording at path %@", path);
        _eventSink(@{@"event" : @"error", @"errorDescription" : @"Video is already recording!"});
    }
    result(nil);
}

-(void)stopVideoRecordingWithResult:(FlutterResult)result {
    NSLog(@"About to stop recording: %d", _isRecording);
    if (_isRecording) {
        __weak MediaRecorder *weakSelf = self;
        [_videoFileRenderer stopVideoRecordingWithCompletion:^{
            NSLog(@"stopVideoRecordingWithCompletion called");
            MediaRecorder *strongSelf = weakSelf;
            NSString *filePath = strongSelf->_videoFileRenderer.filePath;
            strongSelf->_isRecording = NO;
            [strongSelf releaseVideoFileRenderer];
            result(filePath);
            [strongSelf dispose];
            NSLog(@"stopVideoRecording success");
        } onError:^(NSString *errorType, NSString *errorMessage){
            NSLog(@"stopVideoRecording error");
            result([FlutterError errorWithCode:errorType
                                       message:errorMessage
                                       details:nil]);
        }];
    } else {
        if (!result) {
            return;
        }
        NSError *error =
        [NSError errorWithDomain:NSCocoaErrorDomain
                            code:NSURLErrorResourceUnavailable
                        userInfo:@{NSLocalizedDescriptionKey : @"Video is not recording!"}];
        result([error flutterError]);
    }
}

- (void)setPaused:(BOOL)paused{
    NSLog(@"About to set pause to %d", paused);
    [_videoFileRenderer setPaused:paused];
}

- (FlutterError *_Nullable)onCancelWithArguments:(id _Nullable)arguments {
    _eventSink = nil;
    if (_videoFileRenderer) {
        _videoFileRenderer.eventSink = nil;
    }
    return nil;
}

- (FlutterError *_Nullable)onListenWithArguments:(id _Nullable)arguments
                                       eventSink:(nonnull FlutterEventSink)events {
    _eventSink = events;
    if (_videoFileRenderer) {
        _videoFileRenderer.eventSink = events;
    }
    return nil;
}

-(void)releaseVideoFileRenderer{
    if (_videoFileRenderer) {
        if (_videoTrack) {
            [_videoTrack removeRenderer:_videoFileRenderer];
            FlutterCameraCapturer *capturer = (FlutterCameraCapturer*)_videoTrack.source.capturer;
            capturer.camera.audioSamplesInterceptorDelegate = nil;
        }
        if (_samplesInterceptor) {
            [_samplesInterceptor removeSampleInterceptor:_videoFileRenderer];
        }
        [_videoFileRenderer dispose];
        _videoFileRenderer = nil;
    }
}

- (void)didCaptureVideoSamples:(CVPixelBufferRef)pixelBuffer atTime: (CMTime)frameTime rotation:(RTCVideoRotation)rotation{
    if (_videoFileRenderer && _isRecording) {
        [_videoFileRenderer didCaptureVideoSamples:pixelBuffer atTime:frameTime rotation:rotation];
    }
}

- (void)didCaptureAudioSamples:(CMSampleBufferRef)sampleBuffer {
    if (_videoFileRenderer && _isRecording) {
        [_videoFileRenderer didCaptureAudioSamples:sampleBuffer];
    }
}

#pragma mark - CameraSwitchObserver methods

- (void)willSwitchCamera:(bool)isFacing trackId: (NSString*)trackid {
    if ([trackid isEqualToString:_videoTrack.trackId]) {
        if (_videoFileRenderer) {
            [_videoTrack removeRenderer:_videoFileRenderer];
        }
    }
}

- (void)didSwitchCamera:(bool)isFacing trackId: (NSString*)trackid {
    if ([trackid isEqualToString:_videoTrack.trackId]) {
        _mirror = isFacing;
        NSLog(@"Did Switch Media Recorder: facing called: %@", isFacing ? @"YES" : @"NO");
        if (_videoFileRenderer) {
            [_videoFileRenderer setMirror:_mirror];
            [_videoTrack addRenderer:_videoFileRenderer];
        }
    }
}

- (void)didFailSwitch:(NSString*)trackid {
    if ([trackid isEqualToString:_videoTrack.trackId]) {
        if (_videoFileRenderer) {
            [_videoTrack addRenderer:_videoFileRenderer];
        }
    }
}

-(void)dispose{
    [_eventChannel setStreamHandler:nil];
    _eventChannel = nil;
    _eventSink = nil;
    _samplesInterceptor = nil;
    _videoTrack = nil;
}


-(void)dealloc{
    NSLog(@"recorder deallocated");
}

+ (NSDictionary *)extractAudioMetadataWithFile:(NSString *)filename{
    NSURL *videoUrl = [NSURL fileURLWithPath:filename];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:videoUrl options:nil];\
    AVAssetTrack *assetTrack = [[asset tracksWithMediaType:AVMediaTypeAudio] objectAtIndex:0];
    Float64 duration = CMTimeGetSeconds(assetTrack.timeRange.duration);
    NSMutableDictionary *imageBuffer = [NSMutableDictionary dictionary];
    imageBuffer[@"duration"] = [NSNumber numberWithFloat:duration];
    imageBuffer[@"mimeType"] = @"audio/mp4";
    imageBuffer[@"isAudioOnly"] = [NSNumber numberWithBool:YES];
    return imageBuffer;
}

+ (NSDictionary *)extractVideoMetadataWithFile:(NSString *)filename videoSize:(CGSize)videoSize options:(MetaDataOptions*)options{
    NSURL *videoUrl = [NSURL fileURLWithPath:filename];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:videoUrl options:nil];\
    AVAssetTrack *assetTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] objectAtIndex:0];
    Float64 duration = CMTimeGetSeconds(assetTrack.timeRange.duration);
    Float64 seconds = duration / 3;
    NSMutableDictionary *imageBuffer = [NSMutableDictionary dictionary];
    imageBuffer[@"videoWidth"] = [NSNumber numberWithInt:(int)videoSize.width];
    imageBuffer[@"videoHeight"] = [NSNumber numberWithInt:(int)videoSize.height];
    imageBuffer[@"mimeType"] = @"video/mp4";
    imageBuffer[@"duration"] = [NSNumber numberWithFloat:duration];
    imageBuffer[@"frameRate"] = [NSNumber numberWithFloat:assetTrack.nominalFrameRate];
    imageBuffer[@"isAudioOnly"] = [NSNumber numberWithBool:options.audioOnly];
    if (options) {
        AVAssetImageGenerator *generator = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
        generator.appliesPreferredTrackTransform = true;
        //Can set this to improve performance if target size is known before hand
        generator.maximumSize = CGSizeMake(options.thumbnailWidth, options.thumbnailHeight);
        generator.requestedTimeToleranceBefore = kCMTimeZero;
        generator.requestedTimeToleranceAfter = kCMTimeZero;
        CMTime time = CMTimeMakeWithSeconds(seconds, 600);
        NSError* error;
        CGImageRef image = [generator copyCGImageAtTime:time actualTime:NULL error:&error];
        NSData *data;
        if (!error) {
            UIImage *generatedImage=[UIImage imageWithCGImage:image];
            data = UIImageJPEGRepresentation(generatedImage, options.thumbnailQuality);
            FlutterStandardTypedData *flutterBytes = [FlutterStandardTypedData typedDataWithBytes:data];
            imageBuffer[@"thumbnailData"] = flutterBytes;
            imageBuffer[@"thumbnailWidth"] = [NSNumber numberWithUnsignedLong:generatedImage.size.width];
            imageBuffer[@"thumbnailHeight"] = [NSNumber numberWithUnsignedLong:generatedImage.size.height];
        }
    }
    return imageBuffer;
}

@end

@implementation FlutterWebRTCPlugin (MediaRecorder)

- (MediaRecorder *)createMediaRecorder:(NSNumber *)recorderId size:(CGSize)size samplesInterceptor:(SamplesInterceptor*)samplesInterceptor audioOnly:(BOOL)audioOnly {
    return [[MediaRecorder alloc] initWithRecorderId:recorderId videoSize:size samplesInterceptor:samplesInterceptor messenger:self.messenger audioOnly:audioOnly];
}
@end
