//
//  FlutterRTCVideoRecorder.m
//  Pods-Runner
//
//  Created by Onyemaechi Okafor on 9/1/19.
//

#import <Foundation/Foundation.h>
#import "FlutterRTCVideoRecorder.h"
#import "FlutterVideoMixer.h"
#import "MediaRecorder.h"

@interface FlutterRTCVideoRecorder()
@property(nonatomic, strong) FlutterVideoMixer *videoMixer;
@property(strong, nonatomic) NSString *filePath;
@property(strong, nonatomic) AVAssetWriter *videoWriter;
@property(strong, nonatomic) AVAssetWriterInput *videoWriterInput;
@property(strong, nonatomic) AVAssetWriterInput *audioWriterInput;
@property(strong, nonatomic) AVAssetWriterInputPixelBufferAdaptor *assetWriterPixelBufferAdaptor;
@property(strong, nonatomic) AVCaptureVideoDataOutput *videoOutput;
@property(strong, nonatomic) AVCaptureAudioDataOutput *audioOutput;
@end


@implementation FlutterRTCVideoRecorder{
    CGSize _size;
    int _fps;
    BOOL _discont;
    CMTime _startTime, _previousFrameTime, _previousAudioTime;
    CMTime _offsetTime;
    dispatch_queue_t _queue;
    BOOL _audioOnly;
    
}

- (instancetype)initWithRecorderId:(NSNumber *_Nonnull)recorderId videoSize:(CGSize)size framesPerSecond:(int)fps messenger:(NSObject<FlutterBinaryMessenger>*)messenger audioOnly:(BOOL)audioOnly {
    if (self = [super init]) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(willEnterBackground:) name:UIApplicationWillResignActiveNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(willEnterForeground:) name:UIApplicationDidBecomeActiveNotification object:nil];
        _size = size;
        _fps = fps;
        _discont = NO;
        _audioOnly = audioOnly;
        _previousFrameTime = kCMTimeNegativeInfinity;
        _previousAudioTime = kCMTimeNegativeInfinity;
        _offsetTime = kCMTimeZero;
        _eventChannel = [FlutterEventChannel
                         eventChannelWithName:[NSString stringWithFormat:@"FlutterWebRTC/mediaRecorderEvents/%@", recorderId]
                         binaryMessenger:messenger];
        [_eventChannel setStreamHandler:self];
    }
    return self;
}

- (dispatch_queue_t)queue {
    if (!_queue) {
        _queue = dispatch_queue_create("cloudwebrtc.com/WebRTC.Writer.Queue", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(_queue,
                                  dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0));
    }
    return _queue;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    NSLog(@"flutter video recorder deallocated");
}

#pragma mark -- Setter Getter

- (FlutterVideoMixer *)videoMixer{
    if(!_videoMixer){
        _videoMixer = [[FlutterVideoMixer alloc] initWithDelegate:self size:_size framesPerSecond:_fps];
        _videoMixer.delegate = self;
    }
    return _videoMixer;
}

#pragma mark - Public

-(void)addVideoTrack:(RTCVideoTrack *)track isRemote:(BOOL)remote label:(NSString*)label{
    [self.videoMixer onAddVideoTrack:track isRemote:remote label:label];
}


-(void)removeVideoTrack:(RTCVideoTrack *)track isRemote:(BOOL)remote label:(NSString*)label{
    [self.videoMixer onRemoveVideoTrack:track isRemote:remote label:label];
}

-(void)dispose{
    _eventSink = nil;
    [_eventChannel setStreamHandler:nil];
    if (_running) {
        [self setRunning:false];
    }
    _videoWriter = nil;
    _audioWriterInput = nil;
    _videoWriterInput = nil;
    _videoMixer = nil;
    NSLog(@"dispose called for rtc video recorder");
}

#pragma mark -- SamplesInterceptorDelegate

- (void)didCaptureAudioSamples:(nonnull CMSampleBufferRef)sampleBuffer {
    if (!_running || _pause) {
        return;
    }
//    __weak FlutterRTCVideoRecorder *weakSelf = self;
//    dispatch_sync([self queue], ^{
//        FlutterRTCVideoRecorder *strongSelf = weakSelf;
//        [strongSelf processAudioFrame:sampleBuffer];
//    });
    [self processAudioFrame:sampleBuffer];
}

- (void)didCaptureVideoSamples:(nonnull CVPixelBufferRef)pixelBuffer atTime:(CMTime)time rotation:(RTCVideoRotation)rotation {
    if (!_running || _pause) {
        return;
    }
//    __weak FlutterRTCVideoRecorder *weakSelf = self;
//    dispatch_sync([self queue], ^{
//        FlutterRTCVideoRecorder *strongSelf = weakSelf;
//        [strongSelf writeVideoFrame:pixelBuffer atTime:time];
//    });
    [self writeVideoFrame:pixelBuffer atTime:time];
}

- (void)didAudioCaptureFailWithError:(NSError *)error{
    if (_eventSink) {
        _eventSink(@{
            @"event" : @"audio_capture_error",
            @"errorDescription" : [NSString stringWithFormat:@"%@", error.localizedDescription]
        });
    }
}

- (void)didVideoCaptureFailWithError:(NSError *)error{
    if (_eventSink) {
        _eventSink(@{
            @"event" : @"video_capture_error",
            @"errorDescription" : [NSString stringWithFormat:@"%@", error.localizedDescription]
        });
    }
}

- (void)writeVideoFrame:(CVPixelBufferRef)pixelBuffer atTime:(CMTime)frameTime{
    //NSLog(@"GOT pixelBuffer AT time: %d", frameTime);
    if (_videoWriter.status == AVAssetWriterStatusFailed) {
        if (_eventSink) {
            _eventSink(@{
                @"event" : @"error",
                @"errorDescription" : [NSString stringWithFormat:@"%@", _videoWriter.error]
            });
        }
        return;
    }
    // Drop frames forced by images and other things with no time constants
    // Also, if two consecutive times with the same value are added to the movie, it aborts recording, so I bail on that case
    if ( (CMTIME_IS_INVALID(frameTime)))
    {
        //NSLog(@"Dropping video fram due to invalid frametime %lld", frameTime);
        return;
    }
    if ((CMTIME_COMPARE_INLINE(frameTime, ==, _previousFrameTime)))
    {
        //NSLog(@"Dropping video fram due to same frametime %lld", frameTime);
        return;
    }
    if (CMTIME_IS_INDEFINITE(frameTime))
    {
        //NSLog(@"Dropping video fram due to indefinite frametime %lld", frameTime);
        return;
    }
    if (_discont) {
        _discont = NO;
        CMTime current;
        
        if (_offsetTime.value > 0) {
            current = CMTimeSubtract(frameTime, _offsetTime);
        } else {
            current = frameTime;
        }
        
        CMTime offset  = CMTimeSubtract(current, _previousFrameTime);
        
        if (_offsetTime.value == 0) {
            _offsetTime = offset;
        } else {
            _offsetTime = CMTimeAdd(_offsetTime, offset);
        }
    }
    
    if (_offsetTime.value > 0) {
        frameTime = CMTimeSubtract(frameTime, _offsetTime);
        NSLog(@"Offset %lld", _offsetTime.value);
    }
    
    if (_videoWriter.status != AVAssetWriterStatusWriting) {
        [_videoWriter startWriting];
        [_videoWriter startSessionAtSourceTime:frameTime];
        _startTime = frameTime;
    }
    if (_videoWriter.status != AVAssetWriterStatusWriting) {
        if (_videoWriter.status == AVAssetWriterStatusFailed) {
            if (_eventSink) {
                _eventSink(@{
                    @"event" : @"error",
                    @"errorDescription" : [NSString stringWithFormat:@"%@", _videoWriter.error]
                });
            }
        }
        //NSLog(@"Failed to start video at sourceTime:%lld error:%@", frameTime, _videoWriter.error);
        return;
    }
    
    if (_videoWriterInput.readyForMoreMediaData) {
        if (![_assetWriterPixelBufferAdaptor appendPixelBuffer:pixelBuffer withPresentationTime:frameTime]) {
            if (_eventSink) {
                _eventSink(@{
                    @"event" : @"error",
                    @"errorDescription" :
                        [NSString stringWithFormat:@"%@", @"Unable to write to video input"]
                });
            }
        }
    }
    //NSLog(@"writing valid frame for time frametime %lld", frameTime);
    _previousFrameTime = frameTime;
}

- (void)processAudioFrame:(CMSampleBufferRef)sampleBuffer {
    CMTime currentSampleTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    if (_videoWriter.status == AVAssetWriterStatusFailed) {
        if (_eventSink) {
            _eventSink(@{
                @"event" : @"error",
                @"errorDescription" : [NSString stringWithFormat:@"%@", _videoWriter.error]
            });
        }
        NSLog(@"Audio write failed  because status is failed");
        return;
    }
    if ( (CMTIME_IS_INVALID(currentSampleTime)) || (CMTIME_COMPARE_INLINE(currentSampleTime, ==, _previousAudioTime)) || (CMTIME_IS_INDEFINITE(currentSampleTime)) )
    {
        //NSLog(@"Dropping audio fram due to invalid currentSampleTime:%lld, previousSampleTime:%lld", currentSampleTime, _previousAudioTime);
        return;
    }
    if (_videoWriter.status != AVAssetWriterStatusWriting && _audioOnly) {
        [_videoWriter startWriting];
        [_videoWriter startSessionAtSourceTime:currentSampleTime];
        _startTime = currentSampleTime;
    }
    if (_videoWriter.status != AVAssetWriterStatusWriting) {
        if (_videoWriter.status == AVAssetWriterStatusFailed) {
            if (_eventSink) {
                _eventSink(@{
                    @"event" : @"error",
                    @"errorDescription" : [NSString stringWithFormat:@"%@", _videoWriter.error]
                });
            }
        }
        NSLog(@"Audio write failed  because status is not writing");
        return;
    }
    if (!_audioWriterInput.readyForMoreMediaData) {
        NSLog(@"Not ready for media");
        return;
    }
    if (_discont) {
        _discont = NO;
        CMTime current;
        if (_offsetTime.value > 0) {
            current = CMTimeSubtract(currentSampleTime, _offsetTime);
        } else {
            current = currentSampleTime;
        }
        
        CMTime offset = CMTimeSubtract(current, _previousAudioTime);
        
        if (_offsetTime.value == 0) {
            _offsetTime = offset;
        } else {
            _offsetTime = CMTimeAdd(_offsetTime, offset);
        }
    }
    
    if (_offsetTime.value > 0) {
        sampleBuffer = [self adjustTime:sampleBuffer by:_offsetTime];
    }
    
    CFRetain(sampleBuffer);
    currentSampleTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    _previousAudioTime = currentSampleTime;
    
    if (![_audioWriterInput appendSampleBuffer:sampleBuffer]) {
        if (_eventSink) {
            _eventSink(@{
                @"event" : @"error",
                @"errorDescription" :
                    [NSString stringWithFormat:@"%@", @"Unable to write to audio input"]
            });
        }
        NSLog(@"Failed to appen sample buffer");
    } else {
        //NSLog(@"Wrote Audio Samples at frameTime %lld", currentSampleTime.value);
    }
    CFRelease(sampleBuffer);
}

- (CMSampleBufferRef)adjustTime:(CMSampleBufferRef) sample by:(CMTime) offset {
    CMItemCount count;
    CMSampleBufferGetSampleTimingInfoArray(sample, 0, nil, &count);
    CMSampleTimingInfo* pInfo = malloc(sizeof(CMSampleTimingInfo) * count);
    CMSampleBufferGetSampleTimingInfoArray(sample, count, pInfo, &count);
    
    for (CMItemCount i = 0; i < count; i++) {
        pInfo[i].decodeTimeStamp = CMTimeSubtract(pInfo[i].decodeTimeStamp, offset);
        pInfo[i].presentationTimeStamp = CMTimeSubtract(pInfo[i].presentationTimeStamp, offset);
    }
    
    CMSampleBufferRef sout;
    CMSampleBufferCreateCopyWithNewTiming(nil, sample, count, pInfo, &sout);
    free(pInfo);
    
    return sout;
}

- (void)startVideoRecordingAtPath:(NSString *)path result:(FlutterResult)result {
    if (_running) {
        result([FlutterError errorWithCode:@"record_error_started"
                                   message:@"recording already started"
                                   details:nil]);
        return;
    }
    _filePath = path;
    NSLog(@"record destination: %@", _filePath);
    if (![self setupWriterForPath:_filePath]) {
        result([FlutterError errorWithCode:@"record_error_setup"
                                   message:@"Setup Writer Failed!"
                                   details:nil]);
        return;
    }
    _running = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIApplication sharedApplication].idleTimerDisabled = YES;
    });
    [self.videoMixer startCaptureWithCompletion:nil onError:nil];
    result(nil);
}

- (void)stopVideoRecordingWithResult:(FlutterResult)result {
    if (!_running) {
        result([FlutterError errorWithCode:@"record_error_stopped"
                                   message:@"recording not started"
                                   details:nil]);
        return;
    }
    __weak FlutterRTCVideoRecorder *weakSelf = self;
    dispatch_sync([self queue], ^{
        FlutterRTCVideoRecorder *strongSelf = weakSelf;
        [strongSelf doStop:result];
        dispatch_async(dispatch_get_main_queue(), ^{
            [UIApplication sharedApplication].idleTimerDisabled = NO;
        });
    });
}

- (void)doStop:(FlutterResult)result  {
    _offsetTime = kCMTimeZero;
    _running = NO;
    if (_videoWriter.status != AVAssetWriterStatusUnknown) {
        if(_videoWriter.status == AVAssetWriterStatusWriting)
        {
            [_videoWriterInput markAsFinished];
        }
        if(_videoWriter.status == AVAssetWriterStatusWriting)
        {
            [_audioWriterInput markAsFinished];
        }
        __weak FlutterRTCVideoRecorder *weakSelf = self;
        [_videoWriter finishWritingWithCompletionHandler:^{
            FlutterRTCVideoRecorder *strongSelf = weakSelf;
            [strongSelf doStopWithResult:result];
        }];
        NSLog(@"writter stopped");
    } else{
        NSLog(@"no writter started");
        result(nil);
    }
}

- (void)doStopWithResult:(FlutterResult)result {
    __weak FlutterRTCVideoRecorder *weakSelf = self;
    [self.videoMixer stopCaptureWithCompletion:^{
        FlutterRTCVideoRecorder *strongSelf = weakSelf;
        strongSelf->_offsetTime = kCMTimeZero;
        strongSelf->_running = NO;
        self.videoMixer = nil;
        result(nil);
    } onError:^(NSString *errorType, NSString *errorMessage) {
        result([FlutterError errorWithCode:errorType
                                   message:errorMessage
                                   details:nil]);
    }];
}

- (void)setPaused:(BOOL)paused{
    NSLog(@"About to set pause to %d", paused);
    if (_pause != paused) {
        _pause = paused;
        if (_pause) {
            _discont = YES;
        }
    }
}

- (BOOL)setupWriterForPath:(NSString *)path {
    NSError *error = nil;
    NSURL *outputURL;
    if (path != nil) {
        outputURL = [NSURL fileURLWithPath:path];
    } else {
        return NO;
    }
    _videoWriter = [[AVAssetWriter alloc] initWithURL:outputURL
                                             fileType:AVFileTypeQuickTimeMovie
                                                error:&error];
    NSParameterAssert(_videoWriter);
    if (error) {
        return NO;
    }
    NSMutableDictionary * compressionProperties = [[NSMutableDictionary alloc] init];
    [compressionProperties setObject:[NSNumber numberWithInt: 1200000] forKey:AVVideoAverageBitRateKey];
    
    NSDictionary *videoSettings = [NSDictionary
                                   dictionaryWithObjectsAndKeys:AVVideoCodecH264, AVVideoCodecKey,
                                   [NSNumber numberWithInt:_size.width], AVVideoWidthKey,
                                   [NSNumber numberWithInt:_size.height], AVVideoHeightKey,
                                   compressionProperties, AVVideoCompressionPropertiesKey,
                                   nil];
    
    _videoWriterInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                                           outputSettings:videoSettings];
    
    NSDictionary *sourcePixelBufferAttributesDictionary = [NSDictionary dictionaryWithObjectsAndKeys: [NSNumber numberWithInt:kCVPixelFormatType_32BGRA], kCVPixelBufferPixelFormatTypeKey,
                                                           [NSNumber numberWithInt:_size.width], kCVPixelBufferWidthKey,
                                                           [NSNumber numberWithInt:_size.height], kCVPixelBufferHeightKey,
                                                           nil];
    
    _assetWriterPixelBufferAdaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:_videoWriterInput sourcePixelBufferAttributes:sourcePixelBufferAttributesDictionary];
    
    [_videoWriter addInput:_videoWriterInput];
    
    NSParameterAssert(_videoWriterInput);
    _videoWriterInput.expectsMediaDataInRealTime = YES;
    
    // Add the audio input
    AudioChannelLayout acl;
    bzero(&acl, sizeof(acl));
    
    AVAudioSession *sharedAudioSession = [AVAudioSession sharedInstance];
    double preferredHardwareSampleRate;
    
    if ([sharedAudioSession respondsToSelector:@selector(sampleRate)])
    {
        preferredHardwareSampleRate = [sharedAudioSession sampleRate];
    }
    else
    {
        preferredHardwareSampleRate = [[AVAudioSession sharedInstance] currentHardwareSampleRate];
    }
    
    acl.mChannelLayoutTag = kAudioChannelLayoutTag_Mono;
    NSDictionary *audioOutputSettings = nil;
    // Both type of audio inputs causes output video file to be corrupted.
    audioOutputSettings = [NSDictionary
                           dictionaryWithObjectsAndKeys:[NSNumber numberWithInt:kAudioFormatMPEG4AAC], AVFormatIDKey,
                           [NSNumber numberWithFloat:preferredHardwareSampleRate], AVSampleRateKey,
                           [NSNumber numberWithInt:1], AVNumberOfChannelsKey,
                           [NSData dataWithBytes:&acl length:sizeof(acl)],
                           AVChannelLayoutKey, nil];
    _audioWriterInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio
                                                           outputSettings:audioOutputSettings];
    _audioWriterInput.expectsMediaDataInRealTime = YES;
    [_videoWriter addInput:_audioWriterInput];
    return YES;
}

#pragma mark -- FlutterStreamHandler
- (FlutterError *_Nullable)onCancelWithArguments:(id _Nullable)arguments {
    _eventSink = nil;
    return nil;
}

- (FlutterError *_Nullable)onListenWithArguments:(id _Nullable)arguments
                                       eventSink:(nonnull FlutterEventSink)events {
    _eventSink = events;
    return nil;
}

#pragma mark Notification

- (void)willEnterBackground:(NSNotification *)notification {
    [UIApplication sharedApplication].idleTimerDisabled = NO;
}

- (void)willEnterForeground:(NSNotification *)notification {
    [UIApplication sharedApplication].idleTimerDisabled = YES;
}

#pragma mark - CameraSwitchObserver methods

- (void)willSwitchCamera:(bool)isFacing trackId:(NSString*)trackid {
    [self.videoMixer willSwitchCamera:isFacing trackId:trackid];
}

- (void)didSwitchCamera:(bool)isFacing trackId: (NSString*)trackid {
    [self.videoMixer didSwitchCamera:isFacing trackId:trackid];
}

- (void)didFailSwitch:(NSString*)trackid {
    [self.videoMixer didFailSwitch:trackid];
}

@end
