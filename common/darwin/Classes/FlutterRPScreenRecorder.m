#import "FlutterRPScreenRecorder.h"
#if TARGET_OS_IPHONE
#import <ReplayKit/ReplayKit.h>


@implementation FlutterRPScreenRecorder {
    RPScreenRecorder *screenRecorder;
}

- (instancetype)initWithDelegate:(__weak id<RTCVideoCapturerDelegate>)delegate {
    return [self initWithDelegate:delegate samplesInterceptor: nil];
}

- (instancetype)initWithDelegate:(__weak id<RTCVideoCapturerDelegate>)delegate
              samplesInterceptor:(__weak id<SamplesInterceptorDelegate>)interceptorDelegate{
    _samplesInterceptorDelegate = interceptorDelegate;
    return [super initWithDelegate:delegate];
}

- (void)startCapture:(nullable OnSuccess)onSuccess onError:(nullable OnError)onError
{
    if(screenRecorder == NULL)
        screenRecorder = [RPScreenRecorder sharedRecorder];
    
    [screenRecorder setMicrophoneEnabled:NO];
    
    if (![screenRecorder isAvailable]) {
        if (onError) {
            onError(@"Screen recorder is not available!", @"");
        }
        return;
    }
    
    [screenRecorder startCaptureWithHandler:^(CMSampleBufferRef  _Nonnull sampleBuffer, RPSampleBufferType bufferType, NSError * _Nullable error) {
        NSLog(@"startCaptureWithHandler");
        if (bufferType == RPSampleBufferTypeVideo) {// We want video only now
            NSLog(@"RPSampleBufferTypeVideo");
            [self handleSourceBuffer:sampleBuffer sampleType:bufferType];
        }
    } completionHandler:^(NSError * _Nullable error) {
        if (error != nil) {
            if (onError) {
                onError(@"!!! startCaptureWithHandler/completionHandler %@ !!!", error.localizedDescription);
            }
            return;
        }
        if (onSuccess) {
            NSLog(@"Screen Capture success");
            onSuccess();
        }
    }];
}

- (void)stopCapture:(nullable  OnSuccess)onSuccess onError:(nullable OnError)onError;
{
    [screenRecorder stopCaptureWithHandler:^(NSError * _Nullable error) {
        if (error != nil) {
            if (onError) {
                onError(@"!!! stopCaptureWithHandler/completionHandler %@ !!!", error.localizedDescription);
            }
            return;
        }
        if (onSuccess) {
            onSuccess();
        }
    }];
}

-(void)handleSourceBuffer:(CMSampleBufferRef)sampleBuffer sampleType:(RPSampleBufferType)sampleType
{
    if (CMSampleBufferGetNumSamples(sampleBuffer) != 1 || !CMSampleBufferIsValid(sampleBuffer) ||
        !CMSampleBufferDataIsReady(sampleBuffer)) {
        return;
    }
    
    
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (pixelBuffer == nil) {
        return;
    }
    
    size_t width = CVPixelBufferGetWidth(pixelBuffer);
    size_t height = CVPixelBufferGetHeight(pixelBuffer);
    NSLog(@"got pixel buffer, width=%ld, height=%ld", width, height);
    //
    //    [source adaptOutputFormatToWidth:width/2 height:height/2 fps:8];
    
    RTCCVPixelBuffer *rtcPixelBuffer = [[RTCCVPixelBuffer alloc] initWithPixelBuffer:pixelBuffer];
    int64_t timeStampNs =
    CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) * NSEC_PER_SEC;
    RTCVideoFrame *videoFrame = [[RTCVideoFrame alloc] initWithBuffer:rtcPixelBuffer
                                                             rotation:RTCVideoRotation_0
                                                          timeStampNs:timeStampNs];
    [self.delegate capturer:self didCaptureVideoFrame:videoFrame];
}

@end

#endif
