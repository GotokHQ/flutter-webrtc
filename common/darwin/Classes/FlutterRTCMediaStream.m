#import <objc/runtime.h>

#import <WebRTC/WebRTC.h>

#import "FlutterRTCFrameCapturer.h"
#import "FlutterRTCMediaStream.h"
#import "FlutterRTCPeerConnection.h"
#import "FlutterRTCVideoSource.h"
#import "FlutterVideoCapturer.h"
#import "FlutterFileCapturer.h"
#import "FlutterScreenCapturer.h"

#if TARGET_OS_IPHONE
#import "FlutterRPScreenRecorder.h"
#endif

@implementation AVCaptureDevice (Flutter)

- (NSString*)positionString {
  switch (self.position) {
    case AVCaptureDevicePositionUnspecified: return @"unspecified";
    case AVCaptureDevicePositionBack: return @"back";
    case AVCaptureDevicePositionFront: return @"front";
  }
  return nil;
}

@end

@implementation  FlutterWebRTCPlugin (RTCMediaStream)

/**
 * {@link https://www.w3.org/TR/mediacapture-streams/#navigatorusermediaerrorcallback}
 */
typedef void (^NavigatorUserMediaErrorCallback)(NSString *errorType, NSString *errorMessage);

/**
 * {@link https://www.w3.org/TR/mediacapture-streams/#navigatorusermediasuccesscallback}
 */
typedef void (^NavigatorUserMediaSuccessCallback)(RTCMediaStream *mediaStream);

- (RTCMediaConstraints *)defaultMediaStreamConstraints {
    NSDictionary *mandatoryConstraints
    = @{ @"minWidth"     : @"1280",
         @"minHeight"    : @"720",
         @"minFrameRate" : @"30" };
    RTCMediaConstraints* constraints =
    [[RTCMediaConstraints alloc]
     initWithMandatoryConstraints:mandatoryConstraints
     optionalConstraints:nil];
    return constraints;
}

/**
 * Initializes a new {@link RTCAudioTrack} which satisfies specific constraints,
 * adds it to a specific {@link RTCMediaStream}, and reports success to a
 * specific callback. Implements the audio-specific counterpart of the
 * {@code getUserMedia()} algorithm.
 *
 * @param constraints The {@code MediaStreamConstraints} which the new
 * {@code RTCAudioTrack} instance is to satisfy.
 * @param successCallback The {@link NavigatorUserMediaSuccessCallback} to which
 * success is to be reported.
 * @param errorCallback The {@link NavigatorUserMediaErrorCallback} to which
 * failure is to be reported.
 * @param mediaStream The {@link RTCMediaStream} which is being initialized as
 * part of the execution of the {@code getUserMedia()} algorithm, to which a
 * new {@code RTCAudioTrack} is to be added, and which is to be reported to
 * {@code successCallback} upon success.
 */
- (void)getUserAudio:(NSDictionary *)constraints
     successCallback:(NavigatorUserMediaSuccessCallback)successCallback
       errorCallback:(NavigatorUserMediaErrorCallback)errorCallback
         mediaStream:(RTCMediaStream *)mediaStream {
    NSString *trackId = [[NSUUID UUID] UUIDString];
    RTCAudioTrack *audioTrack
    = [self.peerConnectionFactory audioTrackWithTrackId:trackId];
    
    [mediaStream addAudioTrack:audioTrack];
    
    successCallback(mediaStream);
}

// TODO: Use RCTConvert for constraints ...
-(void)getUserMedia:(NSDictionary *)constraints
             result:(FlutterResult) result  {
    // Initialize RTCMediaStream with a unique label in order to allow multiple
    // RTCMediaStream instances initialized by multiple getUserMedia calls to be
    // added to 1 RTCPeerConnection instance. As suggested by
    // https://www.w3.org/TR/mediacapture-streams/#mediastream to be a good
    // practice, use a UUID (conforming to RFC4122).
    NSString *mediaStreamId = [[NSUUID UUID] UUIDString];
    RTCMediaStream *mediaStream
    = [self.peerConnectionFactory mediaStreamWithStreamId:mediaStreamId];
    
    [self
     getUserMedia:constraints
     successCallback:^ (RTCMediaStream *mediaStream) {
         NSString *mediaStreamId = mediaStream.streamId;
         
         NSMutableArray *audioTracks = [NSMutableArray array];
         NSMutableArray *videoTracks = [NSMutableArray array];
         
         for (RTCAudioTrack *track in mediaStream.audioTracks) {
             [self.localTracks setObject:track forKey:track.trackId];
             [audioTracks addObject:@{@"id": track.trackId, @"kind": track.kind, @"label": track.trackId, @"enabled": @(track.isEnabled), @"remote": @(NO), @"readyState": @"live"}];
         }
         
         for (RTCVideoTrack *track in mediaStream.videoTracks) {
             [self.localTracks setObject:track forKey:track.trackId];
             [videoTracks addObject:@{@"id": track.trackId, @"kind": track.kind, @"label": track.trackId, @"enabled": @(track.isEnabled), @"remote": @(NO), @"readyState": @"live"}];
         }

         self.localStreams[mediaStreamId] = mediaStream;
         result(@{@"streamId": mediaStreamId, @"audioTracks" : audioTracks, @"videoTracks" : videoTracks });
     }
     errorCallback:^ (NSString *errorType, NSString *errorMessage) {
         result([FlutterError errorWithCode:[NSString stringWithFormat:@"Error %@", errorType]
                                    message:errorMessage
                                    details:nil]);
     }
     mediaStream:mediaStream];
}

/**
 * Initializes a new {@link RTCAudioTrack} or a new {@link RTCVideoTrack} which
 * satisfies specific constraints and adds it to a specific
 * {@link RTCMediaStream} if the specified {@code mediaStream} contains no track
 * of the respective media type and the specified {@code constraints} specify
 * that a track of the respective media type is required; otherwise, reports
 * success for the specified {@code mediaStream} to a specific
 * {@link NavigatorUserMediaSuccessCallback}. In other words, implements a media
 * type-specific iteration of or successfully concludes the
 * {@code getUserMedia()} algorithm. The method will be recursively invoked to
 * conclude the whole {@code getUserMedia()} algorithm either with (successful)
 * satisfaction of the specified {@code constraints} or with failure.
 *
 * @param constraints The {@code MediaStreamConstraints} which specifies the
 * requested media types and which the new {@code RTCAudioTrack} or
 * {@code RTCVideoTrack} instance is to satisfy.
 * @param successCallback The {@link NavigatorUserMediaSuccessCallback} to which
 * success is to be reported.
 * @param errorCallback The {@link NavigatorUserMediaErrorCallback} to which
 * failure is to be reported.
 * @param mediaStream The {@link RTCMediaStream} which is being initialized as
 * part of the execution of the {@code getUserMedia()} algorithm.
 */
- (void)getUserMedia:(NSDictionary *)constraints
     successCallback:(NavigatorUserMediaSuccessCallback)successCallback
       errorCallback:(NavigatorUserMediaErrorCallback)errorCallback
         mediaStream:(RTCMediaStream *)mediaStream {
    // If mediaStream contains no audioTracks and the constraints request such a
    // track, then run an iteration of the getUserMedia() algorithm to obtain
    // local audio content.
    if (mediaStream.audioTracks.count == 0) {
        // constraints.audio
        id audioConstraints = constraints[@"audio"];
        BOOL constraintsIsDictionary = [audioConstraints isKindOfClass:[NSDictionary class]];
        if (audioConstraints && (constraintsIsDictionary || [audioConstraints boolValue])) {
            [self requestAccessForMediaType:AVMediaTypeAudio
                                constraints:constraints
                            successCallback:successCallback
                              errorCallback:errorCallback
                                mediaStream:mediaStream];
            return;
        }
    }
    
    // If mediaStream contains no videoTracks and the constraints request such a
    // track, then run an iteration of the getUserMedia() algorithm to obtain
    // local video content.
    if (mediaStream.videoTracks.count == 0) {
        // constraints.video
        id videoConstraints = constraints[@"video"];
        if (videoConstraints) {
            BOOL requestAccessForVideo
            = [videoConstraints isKindOfClass:[NSNumber class]]
            ? [videoConstraints boolValue]
            : [videoConstraints isKindOfClass:[NSDictionary class]];
#if !TARGET_IPHONE_SIMULATOR
            if (requestAccessForVideo) {
                [self requestAccessForMediaType:AVMediaTypeVideo
                                    constraints:constraints
                                successCallback:successCallback
                                  errorCallback:errorCallback
                                    mediaStream:mediaStream];
                return;
            }
#endif
        }
    }
    
    // There are audioTracks and/or videoTracks in mediaStream as requested by
    // constraints so the getUserMedia() is to conclude with success.
    successCallback(mediaStream);
}

/**
 * Initializes a new {@link RTCVideoTrack} which satisfies specific constraints,
 * adds it to a specific {@link RTCMediaStream}, and reports success to a
 * specific callback. Implements the video-specific counterpart of the
 * {@code getUserMedia()} algorithm.
 *
 * @param constraints The {@code MediaStreamConstraints} which the new
 * {@code RTCVideoTrack} instance is to satisfy.
 * @param successCallback The {@link NavigatorUserMediaSuccessCallback} to which
 * success is to be reported.
 * @param errorCallback The {@link NavigatorUserMediaErrorCallback} to which
 * failure is to be reported.
 * @param mediaStream The {@link RTCMediaStream} which is being initialized as
 * part of the execution of the {@code getUserMedia()} algorithm, to which a
 * new {@code RTCVideoTrack} is to be added, and which is to be reported to
 * {@code successCallback} upon success.
 */
- (void)getUserVideo:(NSDictionary *)constraints
     successCallback:(NavigatorUserMediaSuccessCallback)successCallback
       errorCallback:(NavigatorUserMediaErrorCallback)errorCallback
         mediaStream:(RTCMediaStream *)mediaStream {
    id videoConstraints = constraints[@"video"];
    RTCVideoSource *source = [self.peerConnectionFactory videoSource];
    self.videoCapturer = [[ FlutterCameraCapturer alloc] initWithVideoSource:source constraints:videoConstraints];
    [self.videoCapturer startCapture: ^(void)  {
        NSString *trackUUID = [[NSUUID UUID] UUIDString];
        RTCVideoTrack *videoTrack = [self.peerConnectionFactory videoTrackWithSource:source trackId:trackUUID];
        [mediaStream addVideoTrack:videoTrack];
        successCallback(mediaStream);
    } onError: ^(NSString *errorType, NSString *errorMessage)  {
        errorCallback(errorType, errorMessage);
    }];
    source.capturer = self.videoCapturer;

}


-(void)mediaStreamRelease:(RTCMediaStream *)stream
{
    if (stream) {
        for (RTCVideoTrack *track in stream.videoTracks) {
            [self.localTracks removeObjectForKey:track.trackId];
        }
        for (RTCAudioTrack *track in stream.audioTracks) {
            [self.localTracks removeObjectForKey:track.trackId];
        }
        [self.localStreams removeObjectForKey:stream.streamId];
    }
}


/**
 * Obtains local media content of a specific type. Requests access for the
 * specified {@code mediaType} if necessary. In other words, implements a media
 * type-specific iteration of the {@code getUserMedia()} algorithm.
 *
 * @param mediaType Either {@link AVMediaTypAudio} or {@link AVMediaTypeVideo}
 * which specifies the type of the local media content to obtain.
 * @param constraints The {@code MediaStreamConstraints} which are to be
 * satisfied by the obtained local media content.
 * @param successCallback The {@link NavigatorUserMediaSuccessCallback} to which
 * success is to be reported.
 * @param errorCallback The {@link NavigatorUserMediaErrorCallback} to which
 * failure is to be reported.
 * @param mediaStream The {@link RTCMediaStream} which is to collect the
 * obtained local media content of the specified {@code mediaType}.
 */
- (void)requestAccessForMediaType:(NSString *)mediaType
                      constraints:(NSDictionary *)constraints
                  successCallback:(NavigatorUserMediaSuccessCallback)successCallback
                    errorCallback:(NavigatorUserMediaErrorCallback)errorCallback
                      mediaStream:(RTCMediaStream *)mediaStream {
    // According to step 6.2.1 of the getUserMedia() algorithm, if there is no
    // source, fail "with a new DOMException object whose name attribute has the
    // value NotFoundError."
    // XXX The following approach does not work for audio in Simulator. That is
    // because audio capture is done using AVAudioSession which does not use
    // AVCaptureDevice there. Anyway, Simulator will not (visually) request access
    // for audio.
    if (mediaType == AVMediaTypeVideo
        && [AVCaptureDevice devicesWithMediaType:mediaType].count == 0) {
        // Since successCallback and errorCallback are asynchronously invoked
        // elsewhere, make sure that the invocation here is consistent.
        dispatch_async(dispatch_get_main_queue(), ^ {
            errorCallback(@"DOMException", @"NotFoundError");
        });
        return;
    }

#if TARGET_OS_OSX
    if (@available(macOS 10.14, *)) {
#endif
        [AVCaptureDevice
         requestAccessForMediaType:mediaType
         completionHandler:^ (BOOL granted) {
            dispatch_async(dispatch_get_main_queue(), ^ {
                if (granted) {
                    NavigatorUserMediaSuccessCallback scb
                    = ^ (RTCMediaStream *mediaStream) {
                        [self getUserMedia:constraints
                           successCallback:successCallback
                             errorCallback:errorCallback
                               mediaStream:mediaStream];
                    };
                    
                    if (mediaType == AVMediaTypeAudio) {
                        [self getUserAudio:constraints
                           successCallback:scb
                             errorCallback:errorCallback
                               mediaStream:mediaStream];
                    } else if (mediaType == AVMediaTypeVideo) {
                        [self getUserVideo:constraints
                           successCallback:scb
                             errorCallback:errorCallback
                               mediaStream:mediaStream];
                    }
                } else {
                    // According to step 10 Permission Failure of the getUserMedia()
                    // algorithm, if the user has denied permission, fail "with a new
                    // DOMException object whose name attribute has the value
                    // NotAllowedError."
                    errorCallback(@"DOMException", @"NotAllowedError");
                }
            });
        }];
#if TARGET_OS_OSX
    } else {
        // Fallback on earlier versions
        NavigatorUserMediaSuccessCallback scb
        = ^ (RTCMediaStream *mediaStream) {
            [self getUserMedia:constraints
               successCallback:successCallback
                 errorCallback:errorCallback
                   mediaStream:mediaStream];
        };
        if (mediaType == AVMediaTypeAudio) {
            [self getUserAudio:constraints
               successCallback:scb
                 errorCallback:errorCallback
                   mediaStream:mediaStream];
        } else if (mediaType == AVMediaTypeVideo) {
            [self getUserVideo:constraints
               successCallback:scb
                 errorCallback:errorCallback
                   mediaStream:mediaStream];
        }
    }
#endif
}

#if TARGET_OS_IPHONE
-(void)getDisplayMedia:(NSDictionary *)constraints
                result:(FlutterResult)result {
    
    RTCVideoSource *videoSource = [self.peerConnectionFactory videoSource];
    FlutterScreenCapturer *screenCapturer = [[FlutterScreenCapturer alloc] initWithVideoSource:videoSource samplesInterceptor:nil constraints:constraints];
    [screenCapturer startCapture:^{
        NSString *trackUUID = [[NSUUID UUID] UUIDString];
        RTCVideoTrack *track = [self.peerConnectionFactory videoTrackWithSource:videoSource trackId:trackUUID];
        videoSource.capturer = screenCapturer;
        NSString *mediaStreamId = [[NSUUID UUID] UUIDString];
        RTCMediaStream *mediaStream = [self.peerConnectionFactory mediaStreamWithStreamId:mediaStreamId];
        [mediaStream addVideoTrack:track];
        self.localStreams[mediaStreamId] = mediaStream;
        NSMutableArray *audioTracks = [NSMutableArray array];
        NSMutableArray *videoTracks = [NSMutableArray array];
        for (RTCVideoTrack *track in mediaStream.videoTracks) {
            [self.localTracks setObject:track forKey:track.trackId];
            [videoTracks addObject:@{@"id": track.trackId, @"kind": track.kind, @"label": track.trackId, @"enabled": @(track.isEnabled), @"remote": @(NO), @"readyState": @"live"}];
        }
        result(@{@"streamId": mediaStreamId, @"audioTracks" : audioTracks, @"videoTracks" : videoTracks });
    } onError:^(NSString * errorType, NSString * errorMessage) {
        result([FlutterError errorWithCode:errorType
                                   message:errorMessage
                                   details:nil]);
    }];
}

#endif
-(void)createLocalMediaStream:(FlutterResult)result{
    NSString *mediaStreamId = [[NSUUID UUID] UUIDString];
    RTCMediaStream *mediaStream = [self.peerConnectionFactory mediaStreamWithStreamId:mediaStreamId];

    self.localStreams[mediaStreamId] = mediaStream;
    result(@{@"streamId": [mediaStream streamId] });
}

-(void)getSources:(FlutterResult)result{
  NSMutableArray *sources = [NSMutableArray array];
  NSArray *videoDevices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
  for (AVCaptureDevice *device in videoDevices) {
    [sources addObject:@{
                         @"facing": device.positionString,
                         @"deviceId": device.uniqueID,
                         @"label": device.localizedName,
                         @"kind": @"videoinput",
                         }];
  }
  NSArray *audioDevices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeAudio];
  for (AVCaptureDevice *device in audioDevices) {
    [sources addObject:@{
                         @"facing": @"",
                         @"deviceId": device.uniqueID,
                         @"label": device.localizedName,
                         @"kind": @"audioinput",
                         }];
  }
    result(@{@"sources": sources});
}

-(void)mediaStreamTrackRelease:(RTCMediaStream *)mediaStream  track:(RTCMediaStreamTrack *)track
{
  // what's different to mediaStreamTrackStop? only call mediaStream explicitly?
  if (mediaStream && track) {
    track.isEnabled = NO;
    // FIXME this is called when track is removed from the MediaStream,
    // but it doesn't mean it can not be added back using MediaStream.addTrack
    //TODO: [self.localTracks removeObjectForKey:trackID];
    if ([track.kind isEqualToString:@"audio"]) {
      [mediaStream removeAudioTrack:(RTCAudioTrack *)track];
    } else if([track.kind isEqualToString:@"video"]) {
      [mediaStream removeVideoTrack:(RTCVideoTrack *)track];
    }
  }
}

-(void)mediaStreamTrackSetEnabled:(RTCMediaStreamTrack *)track : (BOOL)enabled
{
  if (track && track.isEnabled != enabled) {
    track.isEnabled = enabled;
  }
}

-(void)mediaStreamTrackHasTorch:(RTCMediaStreamTrack *)track result:(FlutterResult) result
{
    if (!self.videoCapturer) {
        result(@NO);
        return;
    }
    if (self.videoCapturer.camera.captureSession.inputs.count == 0) {
        result(@NO);
        return;
    }

    AVCaptureDeviceInput *deviceInput = [self.videoCapturer.camera.captureSession.inputs objectAtIndex:0];
    AVCaptureDevice *device = deviceInput.device;

    result(@([device isTorchModeSupported:AVCaptureTorchModeOn]));
}

-(void)mediaStreamTrackSetTorch:(RTCMediaStreamTrack *)track torch:(BOOL)torch result:(FlutterResult)result
{
    if (!self.videoCapturer) {
        NSLog(@"Video capturer is null. Can't set torch");
        return;
    }
    if (self.videoCapturer.camera.captureSession.inputs.count == 0) {
        NSLog(@"Video capturer is missing an input. Can't set torch");
        return;
    }

    AVCaptureDeviceInput *deviceInput = [self.videoCapturer.camera.captureSession.inputs objectAtIndex:0];
    AVCaptureDevice *device = deviceInput.device;

    if (![device isTorchModeSupported:AVCaptureTorchModeOn]) {
        NSLog(@"Current capture device does not support torch. Can't set torch");
        return;
    }

    NSError *error;
    if ([device lockForConfiguration:&error] == NO) {
        NSLog(@"Failed to aquire configuration lock. %@", error.localizedDescription);
        return;
    }

    device.torchMode = torch ? AVCaptureTorchModeOn : AVCaptureTorchModeOff;
    [device unlockForConfiguration];

    result(nil);
}

-(void)mediaStreamTrackCaptureFrame:(RTCVideoTrack *)track toPath:(NSString *) path result:(FlutterResult)result
{
    if (!self.videoCapturer) {
        NSLog(@"Video capturer is null. Can't capture frame.");
        return;
    }

    self.frameCapturer = [[FlutterRTCFrameCapturer alloc] initWithTrack:track toPath:path result:result];
}

-(void)mediaStreamTrackStop:(RTCMediaStreamTrack *)track
{
    if (track) {
        track.isEnabled = NO;
        [self.localTracks removeObjectForKey:track.trackId];
    }
}

-(void)mediaStreamTrackRelease:(RTCMediaStreamTrack *)track
{
    if (track) {
        track.isEnabled = NO;
        [self.localTracks removeObjectForKey:track.trackId];
    }
}

-(void)mediaStreamTrackSwitchCamera:(RTCMediaStreamTrack *)track result:(FlutterResult)result;
{
    RTCVideoTrack *videoTrack = (RTCVideoTrack *)track;
    RTCVideoSource *source = videoTrack.source;
    if (source.capturer) {
        id<FlutterVideoCapturer> capturer = source.capturer;
        dispatch_sync(self.dispatchQueue, ^() {
            for (id<CameraSwitchObserver> observer in self.cameraListeners) {
                [observer willSwitchCamera:capturer.facing trackId:videoTrack.trackId];
                NSLog(@"willSwitchCamera to %d", capturer.facing);
            }
        });
        [capturer switchCamera: ^(){
            dispatch_sync(self.dispatchQueue, ^() {
                for (id<CameraSwitchObserver> observer in self.cameraListeners) {
                    [observer didSwitchCamera:capturer.facing trackId:videoTrack.trackId];
                    NSLog(@"didSwitchCamera to %d", capturer.facing);
                }
            });
            result(nil);
        } onError: ^(NSString *errorType, NSString *errorMessage) {
            dispatch_sync(self.dispatchQueue, ^() {
                for (id<CameraSwitchObserver> observer in self.cameraListeners) {
                    [observer didFailSwitch:videoTrack.trackId];
                    NSLog(@"didFailSwitch to %@", videoTrack.trackId);
                }
            });
            result([FlutterError errorWithCode:errorType
                                       message:errorMessage
                                       details:nil]);
        } ];
    }
}

-(void)mediaStreamTrackRestartCamera:(RTCMediaStreamTrack *)track result:(FlutterResult)result
{
    RTCVideoTrack *videoTrack = (RTCVideoTrack *)track;
    RTCVideoSource *source = videoTrack.source;
    if (source.capturer) {
        id<FlutterVideoCapturer> capturer = source.capturer;
        [capturer restartCapture: ^(){
            result(nil);
        } onError: ^(NSString *errorType, NSString *errorMessage) {
            result([FlutterError errorWithCode:errorType
                                       message:errorMessage
                                       details:nil]);
        } ];
    }
}

-(void)mediaStreamTrackStop:(RTCMediaStreamTrack *)track result:(FlutterResult)result
{
    if ([track isKindOfClass:[RTCVideoTrack class]]){
        RTCVideoTrack *videoTrack = (RTCVideoTrack *)track;
        RTCVideoSource *source = videoTrack.source;
        if ([source.capturer isKindOfClass:[FlutterCameraCapturer class]]) {
            NSLog(@"mediaStreamTrackStop");
            FlutterCameraCapturer *capturer = (FlutterCameraCapturer *)source.capturer;
            [capturer stopRunning: ^(){
                result(nil);
            } onError: ^(NSString *errorType, NSString *errorMessage) {
                result([FlutterError errorWithCode:errorType
                                           message:errorMessage
                                           details:nil]);
            } ];
        } else if (source.capturer) {
            id<FlutterVideoCapturer> capturer = source.capturer;
            [capturer stopCapture:nil onError:nil];
            result(nil);
        }
    } else {
        result(nil);
    }
}

-(void)mediaStreamTrackStart:(RTCMediaStreamTrack *)track result:(FlutterResult)result
{
    if ([track isKindOfClass:[RTCVideoTrack class]]){
        RTCVideoTrack *videoTrack = (RTCVideoTrack *)track;
        RTCVideoSource *source = videoTrack.source;
        if ([source.capturer isKindOfClass:[FlutterCameraCapturer class]]) {
            NSLog(@"mediaStreamTrackStart");
            FlutterCameraCapturer *capturer = (FlutterCameraCapturer *)source.capturer;
            [capturer startRunning: ^(){
                result(nil);
            } onError: ^(NSString *errorType, NSString *errorMessage) {
                result([FlutterError errorWithCode:errorType
                                           message:errorMessage
                                           details:nil]);
            } ];
        } else if (source.capturer) {
            id<FlutterVideoCapturer> capturer = source.capturer;
            [capturer startCapture:nil onError:nil];
            result(nil);
        }
    } else {
        result(nil);
    }
}

-(void)mediaStreamTrackAdaptOutputFormat:(RTCMediaStreamTrack *)track width:(int)width height:(int)height frameRate:(int)frameRate  result:(FlutterResult)result
{
    RTCVideoTrack *videoTrack = (RTCVideoTrack *)track;
    RTCVideoSource *source = videoTrack.source;
    [source adaptOutputFormatToWidth:width height:height fps:frameRate];
    result(nil);
}

-(void)mediaStreamTrackDispose:(RTCMediaStreamTrack *)track
{
    if (!track) {
        return;
    }
    track.isEnabled = NO;
    if ([track isKindOfClass:[RTCVideoTrack class]]){
        RTCVideoTrack *videoTrack = (RTCVideoTrack *)track;
        RTCVideoSource *source = videoTrack.source;
        if (source.capturer) {
            id<FlutterVideoCapturer> capturer = source.capturer;
            [capturer stopCapture:nil onError:nil];
        }
        source.capturer = nil;
        self.videoCapturer = nil;
    }
    [self.localTracks removeObjectForKey:track.trackId];
}

@end
