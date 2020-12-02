//
//  SimpleVideoRecorder.m
//  Pods-Runner
//
//  Created by Onyemaechi Okafor on 2/11/19.
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
#import "VideoFileRenderer.h"
#import "FlutterGLFilter.h"
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import "MTLRenderer.h"
#import "MTLRGBRenderer.h"
#import "MTLNV12Renderer.h"
#import "MTLI420Renderer.h"
#import "MTLColorSwizzleRenderer.h"

@interface VideoFileRenderer()
    @property(strong, nonatomic) NSString *filePath;
    @property(strong, nonatomic) AVAssetWriter *videoWriter;
    @property(strong, nonatomic) AVAssetWriterInput *videoWriterInput;
    @property(strong, nonatomic) AVAssetWriterInput *audioWriterInput;
    @property(strong, nonatomic) AVAssetWriterInputPixelBufferAdaptor *assetWriterPixelBufferAdaptor;
    @property(strong, nonatomic) AVCaptureVideoDataOutput *videoOutput;
    @property(strong, nonatomic) AVCaptureAudioDataOutput *audioOutput;
    @property(nonatomic) MTLI420Renderer *rendererI420;
    @property(nonatomic) MTLNV12Renderer *rendererNV12;
    @property(nonatomic) MTLRGBRenderer *rendererRGB;
@end

@implementation VideoFileRenderer
{
    BOOL _discont;
    CMTime _startTime, _previousFrameTime, _previousAudioTime;
    CMTime _offsetTime;
    RTCVideoTrack *_videoTrack;
    CVPixelBufferRef _renderTarget;
    RTCVideoRotation _rotation;
    CGSize _size;
    id<MTLTexture> _texture;
    int64_t _lastDrawnFrameTimeStampNs;
    dispatch_queue_t _processingQueue;
    CGSize _frameSize;
    id<MTLDevice> _device;
    CVMetalTextureCacheRef _renderTextureCache;
}

@synthesize filePath = _filePath;

- (instancetype)initWithPath:(NSString *)path size:(CGSize)size eventSink:(__weak FlutterEventSink)sink audioOnly:(BOOL)audioOnly{
    self = [super init];
    NSAssert(self, @"super init cannot be nil");
    _filePath = path;
    _discont = NO;
    _previousFrameTime = kCMTimeNegativeInfinity;
    _previousAudioTime = kCMTimeNegativeInfinity;
    _offsetTime = kCMTimeZero;
    _rotation = RTCVideoRotation_0;
    _frameSize = CGSizeZero;
    _size = size;
    _eventSink = sink;
    _mirror = NO;
    [self initGL];
    return self;
}

- (void)initGL {
    _device = MTLCreateSystemDefaultDevice();
}

+ (MTLColorSwizzleRenderer *)createColorSwizzleThroughRenderer:(id<MTLDevice>)device {
    return [[MTLColorSwizzleRenderer alloc] initWithDevice:device];
}

+ (MTLNV12Renderer *)createNV12Renderer:(id<MTLDevice>)device {
    return [[MTLNV12Renderer alloc] initWithDevice:device];
}

+ (MTLRGBRenderer *)createRGBRenderer:(id<MTLDevice>)device {
    return [[MTLRGBRenderer alloc] initWithDevice:device];
}
+ (MTLI420Renderer *)createI420Renderer:(id<MTLDevice>)device {
    return [[MTLI420Renderer alloc] initWithDevice:device];
}

#pragma mark -
#pragma mark Frame rendering

- (BOOL)initializeTextureCache {
    CVReturn status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, _device,
                                       nil, &_renderTextureCache);
    if (status != kCVReturnSuccess) {
        NSLog(@"Metal: Failed to initialize metal texture cache. Return status is %d", status);
        return NO;
    }
    return YES;
}


- (void)createDataFBO {
    if (!_renderTextureCache) {
        [self initializeTextureCache];
    }
    CVMetalTextureRef textureOut;
    CFDictionaryRef empty; // empty value for attr value.
    CFMutableDictionaryRef attrs;
    empty = CFDictionaryCreate(kCFAllocatorDefault, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks); // our empty IOSurface properties dictionary
    attrs = CFDictionaryCreateMutable(kCFAllocatorDefault, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(attrs, kCVPixelBufferIOSurfacePropertiesKey, empty);
    
    CVReturn err = CVPixelBufferCreate(kCFAllocatorDefault, (int)_size.width, (int)_size.height, kCVPixelFormatType_32BGRA, attrs, &_renderTarget);
    if (err)
    {
        NSLog(@"FBO size: %f, %f", _size.width, _size.height);
        NSAssert(NO, @"Error at CVPixelBufferCreate %d", err);
    }
    err = CVMetalTextureCacheCreateTextureFromImage(
                                                                kCFAllocatorDefault, _renderTextureCache, _renderTarget, nil, MTLPixelFormatBGRA8Unorm,
                                                                _size.width, _size.height, 0, &textureOut);
    
    if (err)
    {
        NSAssert(NO, @"Error at CVOpenGLESTextureCacheCreateTextureFromImage %d", err);
    }
    
    CFRelease(attrs);
    CFRelease(empty);
    _texture = CVMetalTextureGetTexture(textureOut);
    CVBufferRelease(textureOut);
    NSLog(@"created FBO with size: %f, %f", _size.width, _size.height);
}

- (void)destroyDataFBO;
{
    if (_renderTarget)
    {
        CVBufferRelease(_renderTarget);
    }
    if (_renderTextureCache) {
        CFRelease(_renderTextureCache);
    }
    _renderTextureCache = nil;
    _renderTarget = nil;
}

#pragma mark - RTCVideoRenderer methods
- (void)renderFrame:(nullable RTCVideoFrame *)frame{
    // NSLog(@"received frame size width %f", _frameSize.width);
    if (!_texture) {
        NSLog(@"VideoFileRenderer Dropping frame,framebuffer not initialized");
        return;
    }
    self.videoFrame = frame;
    [self processFrame];
}

/**
 * Sets the size of the video frame to render.
 *
 * @param size The size of the video frame to render.
 */
- (void)setSize:(CGSize)size {
    if (CGSizeEqualToSize(_size, CGSizeZero)) {
        _size = size;
        [self destroyDataFBO];
        [self createDataFBO];
        [self setupWriterForPath:_filePath];
    }
}

- (void)processFrame {
    if (!_isRecording || _isPaused) {
        return;
    }
    RTCVideoFrame *frame = self.videoFrame;
    if (!frame || frame.timeStampNs == _lastDrawnFrameTimeStampNs) {
        NSLog(@"returning same frame");
        return;
    }
    int frameWidth = frame.width;
    int frameHeight = frame.height;
    if (frameWidth == 0 || frameHeight == 0) {
        return;
    }
    if (CGSizeEqualToSize(_frameSize, CGSizeZero) || _frameSize.height != frameHeight ||
        _frameSize.width != frameWidth) {
        _frameSize = CGSizeMake(frameWidth, frameHeight);
    }
    
    CMTime frameTime = CMTimeMake(frame.timeStampNs, NSEC_PER_SEC);
    
    if (!_texture) {
        NSLog(@"Dropping frame,framebbuffer not initialized");
        return;
    }
    if (CGSizeEqualToSize(_frameSize, CGSizeZero)){
        return;
    }
    FlutterMTLRenderer *renderer;
    if ([frame.buffer isKindOfClass:[RTCCVPixelBuffer class]]) {
        RTCCVPixelBuffer *buffer = (RTCCVPixelBuffer*)frame.buffer;
        const OSType pixelFormat = CVPixelBufferGetPixelFormatType(buffer.pixelBuffer);
        if (pixelFormat == kCVPixelFormatType_32BGRA || pixelFormat == kCVPixelFormatType_32ARGB) {
            if (!self.rendererRGB) {
                self.rendererRGB = [VideoFileRenderer createRGBRenderer:_device];
            }
            renderer = self.rendererRGB;
        } else {
            if (!self.rendererNV12) {
                self.rendererNV12 = [VideoFileRenderer createNV12Renderer:_device];
            }
            renderer = self.rendererNV12;
        }
    } else {
        if (!self.rendererI420) {
            self.rendererI420 = [VideoFileRenderer createI420Renderer:_device];
        }
        renderer = self.rendererI420;
    }
    
    [renderer drawFrame:frame inTexture:_texture rotation:[self rtcRotationToGPURotation:frame.rotation] fit:RTCVideoViewObjectFitCover displayWidth:_size.width displayHeight:_size.height];
    _lastDrawnFrameTimeStampNs = frame.timeStampNs;
    CVPixelBufferRef pixel_buffer =_renderTarget;
    CVPixelBufferLockBaseAddress(pixel_buffer, 0);
    [self writeVideoFrame:_renderTarget atTime: frameTime];
    CVPixelBufferUnlockBaseAddress(pixel_buffer, 0);
    self.videoFrame = nil;
    frame = nil;
}

- (void)didCaptureVideoSamples:(CVPixelBufferRef)pixelBuffer atTime:(CMTime)frameTime rotation:(RTCVideoRotation)rotation{
    if (!_isRecording || _isPaused) {
        return;
    }
    NSLog(@"Got Video Samples at frameTime %lld", frameTime);
    [self processPixelBuffer:pixelBuffer atTime:frameTime rotation:rotation];
}

- (void)processPixelBuffer:(CVPixelBufferRef)pixelBuffer atTime: (CMTime)frameTime rotation:(RTCVideoRotation)rotation{
    if (!_isRecording || _isPaused) {
        return;
    }
    if (!_texture) {
        NSLog(@"Dropping frame,framebbuffer not initialized");
        return;
    }
    CVPixelBufferRetain(pixelBuffer);
    FlutterMTLRenderer *renderer;
    const OSType pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);
    if (pixelFormat == kCVPixelFormatType_32BGRA || pixelFormat == kCVPixelFormatType_32ARGB) {
        if (!self.rendererRGB) {
            self.rendererRGB = [VideoFileRenderer createRGBRenderer:_device];
        }
        renderer = self.rendererRGB;
    } else {
        if (!self.rendererNV12) {
            self.rendererNV12 = [VideoFileRenderer createNV12Renderer:_device];
        }
        renderer = self.rendererNV12;
    }
    
    RTCCVPixelBuffer *rtcPixelBuffer = [[RTCCVPixelBuffer alloc] initWithPixelBuffer:pixelBuffer];
    int64_t timeStampNs = CMTimeGetSeconds(frameTime) * NSEC_PER_SEC;
    RTCVideoFrame *frame = [[RTCVideoFrame alloc] initWithBuffer:rtcPixelBuffer
                                                             rotation:rotation
                                                          timeStampNs:timeStampNs];
    [renderer drawFrame:frame inTexture:_texture rotation:[self rtcRotationToGPURotation:frame.rotation] fit:RTCVideoViewObjectFitCover displayWidth:_size.width displayHeight:_size.height];
    CVPixelBufferRef pixel_buffer =_renderTarget;
    CVPixelBufferLockBaseAddress(pixel_buffer, 0);
    [self writeVideoFrame:_renderTarget atTime:frameTime];
    CVPixelBufferUnlockBaseAddress(pixel_buffer, 0);
    CVPixelBufferRelease(pixelBuffer);
}

- (void)writeVideoFrame:(CVPixelBufferRef)pixelBuffer atTime:(CMTime)frameTime{
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
    if ( (CMTIME_IS_INVALID(frameTime)) || (CMTIME_COMPARE_INLINE(frameTime, ==, _previousFrameTime)) || (CMTIME_IS_INDEFINITE(frameTime)) )
    {
        NSLog(@"Dropping video fram due to invalid frametime %lld", frameTime);
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
        NSLog(@"Failed to start video at sourceTime:%lld error:%@", frameTime, _videoWriter.error);
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
    _previousFrameTime = frameTime;
}

- (void)didCaptureAudioSamples:(CMSampleBufferRef)sampleBuffer {
    if (!_isRecording || _isPaused) {
        return;
    }
    [self processAudioFrame:sampleBuffer];
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
        NSLog(@"Dropping audio fram due to invalid sampletime %lld", currentSampleTime);
        return;
    }
    if (_videoWriter.status != AVAssetWriterStatusWriting) {
        return;
//        [_videoWriter startWriting];
//        [_videoWriter startSessionAtSourceTime:currentSampleTime];
//        _startTime = currentSampleTime;
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
        // NSLog(@"Wrote Audio Samples at frameTime %lld", currentSampleTime.value);
    }
    CFRelease(sampleBuffer);
}

- (void)startVideoRecordingWithCompletion:(VideoFileRendererSuccessCallback)onComplete onError:(VideoFileRendererErrorCallback)onError{
    if (_isRecording) {
        if (_eventSink) {
            _eventSink(@{@"event" : @"error", @"errorDescription" : @"Video is already recording!"});
        }
        if (onError) {
            onError(@"error", @"Video is already recording!");
        }
        return;
    }
    [self doStartVideoRecordingWithCompletion:onComplete onError:onError];
}

- (void)doStartVideoRecordingWithCompletion:(VideoFileRendererSuccessCallback)onComplete onError:(VideoFileRendererErrorCallback)onError {
    _isRecording = YES;
    if (onComplete) {
        onComplete();
    }
}

- (void)stopVideoRecordingWithCompletion:(VideoFileRendererSuccessCallback)onComplete onError:(VideoFileRendererErrorCallback)onError{
    if (!_isRecording) {
        if (onError) {
            onError(@"error", @"Video is not recording!");
        }
        return;
    }
    [self doStopVideoRecordingWithCompletion:onComplete onError:onError];
}

- (void)doStopVideoRecordingWithCompletion:(VideoFileRendererSuccessCallback)onComplete onError:(VideoFileRendererErrorCallback)onError{
    _isRecording = NO;
    _offsetTime = kCMTimeZero;
    if (_videoWriter.status != AVAssetWriterStatusUnknown) {
        if(_videoWriter.status == AVAssetWriterStatusWriting)
        {
            [_videoWriterInput markAsFinished];
        }
        if(_videoWriter.status == AVAssetWriterStatusWriting)
        {
            [_audioWriterInput markAsFinished];
        }
        if (onComplete) {
            [_videoWriter finishWritingWithCompletionHandler:onComplete];
        } else {
            [_videoWriter finishWritingWithCompletionHandler:^{}];
        }
    } else {
        if (onComplete) {
            onComplete();
        }
    }
}
- (void)setPaused:(BOOL)paused{
    NSLog(@"About to set pause to %d", paused);
    if (_isPaused != paused) {
        _isPaused = paused;
        if (_isPaused) {
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

-(void)dispose{
    _eventSink = nil;
    self.videoFrame = nil;
    if (_isRecording) {
        [self stopVideoRecordingWithCompletion:nil onError:nil];
    }
    _videoWriter = nil;
    _audioWriterInput = nil;
    _videoWriterInput = nil;
    _rendererI420 = nil;
    _rendererNV12 = nil;
    _rendererRGB = nil;
    _texture = nil;
    [self destroyDataFBO];
    NSLog(@"dispose called for recorder");
}

-(void)dealloc{
    NSLog(@"video filer renderer deallocated");
    // [self dispose];
}


- (CMTime)duration {
    if( ! CMTIME_IS_VALID(_startTime) )
        return kCMTimeZero;
    if( ! CMTIME_IS_NEGATIVE_INFINITY(_previousFrameTime) )
        return CMTimeSubtract(_previousFrameTime, _startTime);
    if( ! CMTIME_IS_NEGATIVE_INFINITY(_previousAudioTime) )
        return CMTimeSubtract(_previousAudioTime, _startTime);
    return kCMTimeZero;
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

-(GPUImageRotationMode)rtcRotationToGPURotation:(RTCVideoRotation )rotation{
    RTCVideoSource *source = _videoTrack.source;
    BOOL usingFrontCamera = NO;
    if (source.capturer) {
        FlutterCameraCapturer *capturer = source.capturer;
        usingFrontCamera = capturer.facing;
    }
    return [FlutterGLFilter rtcRotationToGPURotation:rotation mirror:_mirror usingFrontCamera:_mirror];
}

@end
